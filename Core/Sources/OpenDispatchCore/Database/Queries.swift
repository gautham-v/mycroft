import Foundation
import GRDB

/// A thumbnail backfill target (fetcher.ts `ThumbTarget`).
public struct ThumbnailTarget: Sendable, Hashable {
    public var id: Int64
    public var url: String
    public init(id: Int64, url: String) {
        self.id = id
        self.url = url
    }
}

/// Synchronous query building blocks (port of src/lib/queries.ts and the route handlers' SQL).
/// Each takes a GRDB `Database`, so several can run inside one transaction:
///
///     try await appDatabase.writer.write { db in
///         let rows = try Queries.upsertItems(db, sourceId: id, items: parsed)
///         try Queries.markSourceFetched(db, sourceId: id, error: nil, update: .init())
///     }
public enum Queries {

    // MARK: Items

    /// WHERE conditions for view/source/folder/filter/search. `src` aliases the joined sources table.
    ///
    /// `topic` is the topic source the query's `sourceId` names, when it does (see `topicScope`).
    static func conditions(_ q: ItemQuery, src: TableAlias<Source>, topic: Source? = nil) -> [SQLExpression] {
        var c: [SQLExpression] = []
        let kind = src[Source.Columns.kind]
        let isPost = AppDatabase.isPostFunction(src[Source.Columns.url])
        switch q.view {
        case .all: break
        case .saved: c.append(Item.Columns.isSaved == true)
        case .video: c.append(kind == SourceKind.youtube.rawValue)
        case .podcasts: c.append(kind == SourceKind.podcast.rawValue)
        case .posts: c.append(isPost == true)
        case .articles:
            c.append(![SourceKind.youtube.rawValue, SourceKind.podcast.rawValue].contains(kind))
            c.append(isPost == false)
        }
        // Links opened from a new tab aren't part of the feed: they list only once saved.
        if q.view != .saved, q.sourceId == nil { c.append(!OpenedLinks.feedURLs.contains(src[Source.Columns.feedUrl])) }
        // Topic items stay out of the curated views: they list in their topic, Saved and History.
        if q.view != .saved, q.sourceId == nil { c.append(kind != SourceKind.topic.rawValue) }
        // Muted sources and folders stay out of the feeds; their own lists, Saved and a search still show them.
        if q.view != .saved, q.sourceId == nil, q.folderId == nil, q.searchTerms.isEmpty {
            c.append(src[Source.Columns.isMuted] == false)
            c.append(SQL("""
                NOT EXISTS (SELECT 1 FROM folders f WHERE f.id = \(src[Source.Columns.folderId]) AND f.is_muted = 1)
                """).sqlExpression)
        }
        if let s = q.sourceId {
            // A topic lists one row per story: the articles behind a lead, the Hacker News thread about it and the posts sharing it
            // list with the lead.
            if topic != nil { c.append(Item.Columns.storyId == nil) }
            if let options = topic?.topicOptions, options.places.subscriptions {
                // The topic's own matches, plus what the user's subscriptions say about the keyword.
                let match = SQL("""
                    opendispatch_topic_matches(\(Item.Columns.title), \(Item.Columns.summary), \(options.keyword), \(options.excluded.joined(separator: "\n")))
                    """).sqlExpression
                // An article the topic already stored (its search found a followed site's story too) lists once, as the topic's own.
                let stored = SQL("""
                    NOT EXISTS (SELECT 1 FROM items t WHERE t.source_id = \(s) AND t.url = "items"."url")
                    """).sqlExpression
                let subscribed = kind != SourceKind.topic.rawValue && !OpenedLinks.feedURLs.contains(src[Source.Columns.feedUrl]) && match && stored
                c.append(Item.Columns.sourceId == s || subscribed)
            } else {
                c.append(Item.Columns.sourceId == s)
            }
        }
        if let expression = topicFilterCondition(q.topicFilter) { c.append(expression) }
        if let f = q.folderId { c.append(src[Source.Columns.folderId] == f) }
        switch q.filter {
        case .hn100?: c.append(Item.Columns.hnPoints >= 100)
        case .labs?: c.append(src[Source.Columns.group] == SourceGroup.labs)
        case .blogs?: c.append(src[Source.Columns.group] == SourceGroup.blogs)
        case nil: break
        }
        for term in q.searchTerms {
            // Backslash escapes LIKE wildcards so they match literally.
            var escaped = ""
            for ch in term {
                if ch == "\\" || ch == "%" || ch == "_" { escaped.append("\\") }
                escaped.append(ch)
            }
            let pat = "%\(escaped)%"
            let cols = [Item.Columns.title, Item.Columns.summary, Item.Columns.author, Item.Columns.contentHtml]
            c.append(cols.map { SQL("\($0) LIKE \(pat) ESCAPE '\\'").sqlExpression }.joined(operator: .or))
        }
        if hidesBlockedVideos(q, topic: topic) {
            c.append(Item.Columns.embedBlocked == nil || Item.Columns.embedBlocked == false)
        }
        if let since = q.since { c.append(Item.Columns.publishedAt >= since) }
        // Hide Read Items: what was read before the list loaded; what's read while it shows stays until the next load.
        if let before = q.hideReadBefore {
            c.append(SQL("""
                NOT EXISTS (SELECT 1 FROM history h WHERE h.source_feed_url = \(src[Source.Columns.feedUrl])
                  AND h.item_guid = \(Item.Columns.guid) AND h.read_at IS NOT NULL AND h.read_at < \(before))
                """).sqlExpression)
        }
        if let cur = q.cursor {
            let sort = sortTime(topic: topic != nil)
            c.append(sort < cur.publishedAt || (sort == cur.publishedAt && Item.Columns.id < cur.id))
        }
        return c
    }

    /// What the list sorts and pages by: the item's time, or in a topic's list a story's newest article (`Item.storyAt`) if it has one.
    static func sortTime(topic: Bool) -> SQLExpression {
        topic ? SQL("coalesce(\(Item.Columns.storyAt), \(Item.Columns.publishedAt))").sqlExpression : Item.Columns.publishedAt.sqlExpression
    }

    /// The topic a query's `sourceId` names, nil for any other source or none.
    static func topicScope(_ db: Database, _ q: ItemQuery) throws -> Source? {
        guard let id = q.sourceId, let s = try Source.fetchOne(db, key: id), s.isTopic else { return nil }
        return s
    }

    /// One page of items, newest first (published_at desc, id desc), each joined with its source. Balanced order
    /// ranks the first page instead (`balancedPage`).
    public static func items(_ db: Database, _ q: ItemQuery) throws -> ItemPage {
        let limit = min(max(q.limit, 1), 200)
        let src = TableAlias<Source>()
        var req = Item
            .select(Item.listSelection)
            .including(required: Item.source.aliased(src))
        let topic = try topicScope(db, q)
        for cond in conditions(q, src: src, topic: topic) { req = req.filter(cond) }
        if q.order == .balanced, q.cursor == nil { return try balancedPage(db, req, topic: topic) }
        let rows = try req
            .order(sortTime(topic: topic != nil).desc, Item.Columns.id.desc)
            .limit(limit + 1)
            .asRequest(of: FeedItem.self)
            .fetchAll(db)
        var page = Array(rows.prefix(limit))
        if let topic { page = try attachStories(db, to: page, topicId: topic.id) }
        let next = rows.count > limit ? page.last?.cursor(inTopic: topic != nil) : nil
        return ItemPage(items: page, nextCursor: next)
    }

    /// Balanced order's first page: the newest items, up to `balancedWindowCount` and no more than `balancedWindowSpan`
    /// older than the newest, so a page can pass `ItemQuery.limit`. Each item counts as `balancedPenalty` older per
    /// newer item from its source in the page; ties keep time order. The cursor is the page's oldest item, so the
    /// next pages go on newest first below it. In a topic's list, where every result shares the topic as its source,
    /// an item's site stands for its source (x.com, bsky.app, youtube.com, each publisher), and times are story times.
    static let balancedWindowCount = 300
    static let balancedWindowSpan: TimeInterval = 48 * 3600
    static let balancedPenalty: TimeInterval = 2 * 3600

    private static func balancedPage(_ db: Database, _ req: QueryInterfaceRequest<Item>, topic: Source?) throws -> ItemPage {
        let inTopic = topic != nil
        let rows = try req
            .order(sortTime(topic: inTopic).desc, Item.Columns.id.desc)
            .limit(balancedWindowCount + 1)
            .asRequest(of: FeedItem.self)
            .fetchAll(db)
        guard let newest = rows.first else { return ItemPage(items: [], nextCursor: nil) }
        let time = { (row: FeedItem) in row.cursor(inTopic: inTopic).publishedAt }
        let cutoff = time(newest).addingTimeInterval(-balancedWindowSpan)
        let window = rows.prefix(balancedWindowCount).prefix { time($0) >= cutoff }
        var seen: [String: Int] = [:]
        var ranked: [(row: FeedItem, at: Date, index: Int)] = []
        for (index, row) in window.enumerated() {
            let key = inTopic ? URLHost.host(of: row.item.url) : String(row.item.sourceId)
            let newer = seen[key, default: 0]
            seen[key] = newer + 1
            ranked.append((row, time(row).addingTimeInterval(-Double(newer) * balancedPenalty), index))
        }
        ranked.sort { $0.at != $1.at ? $0.at > $1.at : $0.index < $1.index }
        var page = ranked.map { $0.row }
        if let topic { page = try attachStories(db, to: page, topicId: topic.id) }
        let next = rows.count > window.count ? window.last?.cursor(inTopic: inTopic) : nil
        return ItemPage(items: page, nextCursor: next)
    }

    /// One list row by id (GET /api/items/:id), without content_html.
    public static func feedItem(_ db: Database, id: Int64) throws -> FeedItem? {
        try Item
            .select(Item.listSelection)
            .including(required: Item.source)
            .filter(Item.Columns.id == id)
            .asRequest(of: FeedItem.self)
            .fetchOne(db)
    }

    /// The full item row, including content_html.
    public static func itemRecord(_ db: Database, id: Int64) throws -> Item? {
        try Item.fetchOne(db, key: id)
    }

    /// PATCH /api/items/:id {is_saved}. Returns the updated row, nil when not found.
    @discardableResult
    public static func setSaved(_ db: Database, itemId: Int64, saved: Bool) throws -> FeedItem? {
        try db.execute(sql: "UPDATE items SET is_saved = ? WHERE id = ?", arguments: [saved, itemId])
        return try feedItem(db, id: itemId)
    }

    /// Item counts per view, per source and per folder.
    public static func counts(_ db: Database) throws -> ItemCounts {
        var out = ItemCounts()
        for view in FeedView.allCases {
            let src = TableAlias<Source>()
            var req = Item.joining(required: Item.source.aliased(src))
            for cond in conditions(ItemQuery(view: view), src: src) { req = req.filter(cond) }
            out.views[view] = try req.fetchCount(db)
        }
        for row in try Row.fetchAll(db, sql: "SELECT source_id, COUNT(*) AS n FROM items GROUP BY source_id") {
            out.sources[row["source_id"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT s.folder_id AS folder_id, COUNT(*) AS n FROM items i JOIN sources s ON s.id = i.source_id
            WHERE s.folder_id IS NOT NULL GROUP BY s.folder_id
            """) {
            out.folders[row["folder_id"]] = row["n"]
        }
        return out
    }

    /// (guid, url, title) of every item stored for a source (dedupe / scraping input).
    public static func storedItemKeys(_ db: Database, sourceId: Int64) throws -> [StoredItemKey] {
        try Row.fetchAll(db, sql: "SELECT guid, url, title FROM items WHERE source_id = ?", arguments: [sourceId]).map {
            StoredItemKey(guid: $0["guid"], url: $0["url"], title: $0["title"])
        }
    }

    /// Insert or update items by (source_id, guid), with the fetcher.ts conflict rules:
    /// title/url/hn_* replaced; summary/thumbnail/audio/duration/quote avatar kept when the new value is null;
    /// content, saved state and published_at untouched. Returns one row per input, in order.
    @discardableResult
    public static func upsertItems(_ db: Database, sourceId: Int64, items: [ParsedItem], now: Date = Date()) throws -> [UpsertedItem] {
        guard !items.isEmpty else { return [] }
        var existing = Set(try String.fetchAll(db, sql: "SELECT guid FROM items WHERE source_id = ?", arguments: [sourceId]))
        let sql = """
            INSERT INTO items (source_id, guid, url, title, summary, author, published_at, thumbnail_url, video_id,
              duration_sec, audio_url, hn_points, hn_comments, hn_comments_url, quote_avatar_url, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, guid) DO UPDATE SET
              title = excluded.title,
              url = excluded.url,
              summary = coalesce(excluded.summary, items.summary),
              thumbnail_url = coalesce(excluded.thumbnail_url, items.thumbnail_url),
              audio_url = coalesce(excluded.audio_url, items.audio_url),
              duration_sec = coalesce(excluded.duration_sec, items.duration_sec),
              hn_points = excluded.hn_points,
              hn_comments = excluded.hn_comments,
              hn_comments_url = excluded.hn_comments_url,
              quote_avatar_url = coalesce(excluded.quote_avatar_url, items.quote_avatar_url)
            RETURNING id, url, thumbnail_url, published_at
            """
        let statement = try db.cachedStatement(sql: sql)
        var out: [UpsertedItem] = []
        out.reserveCapacity(items.count)
        for it in items {
            let args: StatementArguments = [
                sourceId, it.guid, it.url, it.title, it.summary, it.author, it.publishedAt, it.thumbnailUrl, it.videoId,
                it.durationSec, it.audioUrl, it.hnPoints, it.hnComments, it.hnCommentsUrl, it.quoteAvatarUrl, now,
            ]
            guard let row = try Row.fetchOne(statement, arguments: args) else { continue }
            let inserted = !existing.contains(it.guid)
            existing.insert(it.guid)
            out.append(UpsertedItem(id: row["id"], url: row["url"], thumbnailUrl: row["thumbnail_url"], publishedAt: row["published_at"], inserted: inserted))
        }
        return out
    }

    /// Record a fetch attempt: success clears last_error and applies `update`; failure stores the error (max 500 chars).
    public static func markSourceFetched(_ db: Database, sourceId: Int64, at: Date = Date(), error: String?, update: SourceFetchUpdate = SourceFetchUpdate()) throws {
        guard var s = try Source.fetchOne(db, key: sourceId) else { return }
        s.lastFetchedAt = at
        if let error {
            s.lastError = String(error.prefix(500))
        } else {
            s.lastError = nil
            if let k = update.kind { s.kind = k }
            if let g = update.group { s.group = g }
            if let i = update.iconUrl { s.iconUrl = i }
            if let seen = update.seenUrls { s.seenUrls = seen }
        }
        try s.update(db)
    }

    /// Older items of a source without a thumbnail and never tried, newest first (backfillThumbnails' `old` set).
    public static func thumbnailCandidates(_ db: Database, sourceId: Int64, excluding: [Int64], limit: Int) throws -> [ThumbnailTarget] {
        var req = Item
            .select(Item.Columns.id, Item.Columns.url)
            .filter(Item.Columns.sourceId == sourceId && Item.Columns.thumbnailUrl == nil && Item.Columns.thumbnailChecked == false)
        if !excluding.isEmpty { req = req.filter(!excluding.contains(Item.Columns.id)) }
        return try Row.fetchAll(db, req.order(Item.Columns.publishedAt.desc).limit(limit)).map {
            ThumbnailTarget(id: $0["id"], url: $0["url"])
        }
    }

    /// Store a found og:image, only if the item still has no thumbnail; marks it checked.
    public static func setThumbnailFound(_ db: Database, itemId: Int64, url: String) throws {
        try db.execute(sql: "UPDATE items SET thumbnail_url = ?, thumbnail_checked = 1 WHERE id = ? AND thumbnail_url IS NULL", arguments: [url, itemId])
    }

    /// Mark items whose page had no image (final misses), so they aren't refetched.
    public static func markThumbnailChecked(_ db: Database, itemIds: [Int64]) throws {
        guard !itemIds.isEmpty else { return }
        try Item.filter(itemIds.contains(Item.Columns.id)).updateAll(db, Item.Columns.thumbnailChecked.set(to: true))
    }

    /// Cache a fresh extraction (content-cache.ts `contentUpdate`). No-op when contentHtml is nil.
    /// content_rendered is always written; thumbnail_url takes the lead image only when none is stored.
    public static func cacheContent(_ db: Database, itemId: Int64, result: ExtractResult) throws {
        guard let html = result.contentHtml else { return }
        try db.execute(sql: """
            UPDATE items SET content_html = ?, content_rendered = ?, thumbnail_url = coalesce(thumbnail_url, ?) WHERE id = ?
            """, arguments: [html, result.rendered, result.leadImage, itemId])
    }

    /// Delete unsaved items published before `cutoff` (opened links: opened before it), except those
    /// with highlights. Returns rows removed.
    @discardableResult
    public static func pruneOldItems(_ db: Database, before cutoff: Date = Retention.cutoff()) throws -> Int {
        let holders = databaseQuestionMarks(count: OpenedLinks.feedURLs.count)
        let doomed = """
            is_saved = 0
              AND (CASE WHEN source_id IN (SELECT id FROM sources WHERE feed_url IN (\(holders))) THEN created_at ELSE published_at END) < ?
              AND NOT EXISTS (
                SELECT 1 FROM highlights h JOIN sources s ON s.feed_url = h.source_feed_url
                WHERE s.id = items.source_id AND h.item_guid = items.guid)
            """
        let arguments = StatementArguments(OpenedLinks.feedURLs) + [cutoff]
        // A read story whose lead is pruned must stay read: its next article takes over the lead's read mark.
        let readLeads = try readStoryLeads(db, where: doomed, arguments: arguments)
        try db.execute(sql: "DELETE FROM items WHERE \(doomed)", arguments: arguments)
        let removed = db.changesCount
        try repairStories(db, readLeads: readLeads)
        try pruneReadMarks(db)
        return removed
    }

    // MARK: Sources

    /// All sources ordered by position, then title (GET /api/sources). Leaves out the OpenedLinks
    /// holders, which aren't subscriptions, so nothing refreshes, lists, exports or syncs them. Topics are
    /// included (refresh and sync need them); lists of what the user subscribes to use `subscriptions`.
    public static func sources(_ db: Database) throws -> [Source] {
        try Source
            .filter(!OpenedLinks.feedURLs.contains(Source.Columns.feedUrl))
            .order(Source.Columns.position, Source.Columns.title)
            .fetchAll(db)
    }

    public static func source(_ db: Database, id: Int64) throws -> Source? {
        try Source.fetchOne(db, key: id)
    }

    public static func source(_ db: Database, feedUrl: String) throws -> Source? {
        try Source.filter(Source.Columns.feedUrl == feedUrl).fetchOne(db)
    }

    static func nextSourcePosition(_ db: Database, folderId: Int64?) throws -> Int {
        let max: Int? = if let folderId {
            try Int.fetchOne(db, sql: "SELECT max(position) FROM sources WHERE folder_id = ?", arguments: [folderId])
        } else {
            try Int.fetchOne(db, sql: "SELECT max(position) FROM sources WHERE folder_id IS NULL")
        }
        return (max ?? -1) + 1
    }

    /// POST /api/sources after detection: returns the existing source for the same feed_url (existed = true),
    /// or inserts a new one at the end of No Folder. `group` overrides the detected group when non-empty.
    public static func insertSource(_ db: Database, _ found: DetectedFeed, group: String? = nil, now: Date = Date()) throws -> (source: Source, existed: Bool) {
        if let existing = try source(db, feedUrl: found.feedUrl) { return (existing, true) }
        var s = Source(
            title: found.title, url: found.url, feedUrl: found.feedUrl, kind: found.kind,
            group: (group?.isEmpty == false ? group : nil) ?? found.group, iconUrl: found.iconUrl,
            folderId: nil, position: try nextSourcePosition(db, folderId: nil), createdAt: now)
        try s.insert(db)
        return (s, false)
    }

    /// PATCH /api/sources/:id {title}. Throws emptyTitle / notFound.
    @discardableResult
    public static func renameSource(_ db: Database, id: Int64, title: String) throws -> Source {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw QueryError.emptyTitle }
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        s.title = t
        try s.update(db)
        return s
    }

    /// PATCH /api/sources/:id {folder_id}: move to a folder (nil = No Folder), placed at the end of it.
    @discardableResult
    public static func moveSource(_ db: Database, id: Int64, toFolder folderId: Int64?) throws -> Source {
        if let folderId, try Folder.fetchOne(db, key: folderId) == nil { throw QueryError.notFound("Folder") }
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        if s.folderId == folderId { return s }
        s.folderId = folderId
        s.position = try nextSourcePosition(db, folderId: folderId)
        try s.update(db)
        return s
    }

    /// Pin a source to the sidebar's Pinned group (newest pin last) or unpin it. Pinning unhides it, since
    /// a source is either pinned or hidden. Its folder and position are kept so unpinning restores it.
    @discardableResult
    public static func setSourcePinned(_ db: Database, id: Int64, pinned: Bool, now: Date = Date()) throws -> Source {
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        if pinned == s.isPinned { return s }
        s.pinnedAt = pinned ? now : nil
        if pinned { s.isHidden = false }
        try s.update(db)
        return s
    }

    /// Hide a source from the sidebar tree or show it again. Hiding unpins it. The source stays subscribed
    /// and its items still appear in the views.
    @discardableResult
    public static func setSourceHidden(_ db: Database, id: Int64, hidden: Bool) throws -> Source {
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        if hidden == s.isHidden { return s }
        s.isHidden = hidden
        if hidden { s.pinnedAt = nil }
        try s.update(db)
        return s
    }

    /// Keep a source out of the feeds (All, Articles, Posts, Video, Podcasts) or put it back. It stays in the sidebar.
    @discardableResult
    public static func setSourceMuted(_ db: Database, id: Int64, muted: Bool) throws -> Source {
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        if muted == s.isMuted { return s }
        s.isMuted = muted
        try s.update(db)
        return s
    }

    /// Turn notifications for a source's new posts on (from `now`) or off. Turning them on again restarts
    /// the clock, so posts stored while they were off never notify.
    @discardableResult
    public static func setSourceNotify(_ db: Database, id: Int64, on: Bool, now: Date = Date()) throws -> Source {
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Source") }
        if on == s.notifies { return s }
        s.notifySince = on ? now : nil
        try s.update(db)
        return s
    }

    /// New posts to notify about, oldest first: items stored since the last call from sources with
    /// notifications on, stored after they were turned on and published within `NewPostAlert.maxAge`.
    /// Saved items are skipped: those arrive from iCloud, already seen on another device. A story of a topic counts once, for its
    /// lead: another outlet's article and the Hacker News thread about the story are not new posts.
    /// Advances the watermark past every item stored so far, so each item is handed out once, even when
    /// a background and a foreground refresh both ask.
    public static func takeNewPostAlerts(_ db: Database, now: Date = Date()) throws -> [NewPostAlert] {
        let through = try meta(db, MetaKey.notifiedThrough).flatMap(Int64.init) ?? 0
        guard let maxID = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM items"), maxID > through else { return [] }
        let alerts = try Row.fetchAll(db, sql: """
            SELECT i.id, i.title, i.author, i.published_at, s.id AS source_id, s.title AS source_title, s.feed_url AS source_feed_url
            FROM items i JOIN sources s ON s.id = i.source_id
            WHERE i.id > ? AND i.id <= ? AND s.notify_since IS NOT NULL
              AND i.created_at >= s.notify_since AND i.published_at >= ? AND i.is_saved = 0
              AND i.story_id IS NULL
            ORDER BY i.published_at, i.id
            """, arguments: [through, maxID, now.addingTimeInterval(-NewPostAlert.maxAge)]).map {
            NewPostAlert(itemId: $0["id"], title: $0["title"], publishedAt: $0["published_at"],
                         sourceId: $0["source_id"], sourceTitle: $0["source_title"], itemAuthor: $0["author"],
                         isTopic: Topic.isTopicFeedURL($0["source_feed_url"]))
        }
        try setMeta(db, MetaKey.notifiedThrough, String(maxID))
        return alerts
    }

    /// DELETE /api/sources/:id (items cascade). Returns false when not found.
    @discardableResult
    public static func deleteSource(_ db: Database, id: Int64) throws -> Bool {
        try Source.deleteOne(db, key: id)
    }

    /// PATCH /api/sources {order}: each entry gets its folder and the index of its position within that folder.
    public static func reorderSources(_ db: Database, _ order: [SourceOrderEntry]) throws {
        var counters: [Int64?: Int] = [:]
        for entry in order {
            let pos = counters[entry.folderId] ?? 0
            counters[entry.folderId] = pos + 1
            try db.execute(sql: "UPDATE sources SET folder_id = ?, position = ? WHERE id = ?", arguments: [entry.folderId, pos, entry.id])
        }
    }

    // MARK: Folders

    /// Folders in sidebar order (position, then id).
    public static func folders(_ db: Database) throws -> [Folder] {
        try Folder.order(Folder.Columns.position, Folder.Columns.id).fetchAll(db)
    }

    /// POST /api/folders: create at the bottom.
    @discardableResult
    public static func createFolder(_ db: Database, title: String, now: Date = Date()) throws -> Folder {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw QueryError.emptyTitle }
        let max = try Int.fetchOne(db, sql: "SELECT max(position) FROM folders")
        var f = Folder(title: t, position: (max ?? -1) + 1, createdAt: now)
        try f.insert(db)
        return f
    }

    /// PATCH /api/folders/:id {title}.
    @discardableResult
    public static func renameFolder(_ db: Database, id: Int64, title: String) throws -> Folder {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw QueryError.emptyTitle }
        guard var f = try Folder.fetchOne(db, key: id) else { throw QueryError.notFound("Folder") }
        f.title = t
        try f.update(db)
        return f
    }

    /// Keep every source in a folder out of the feeds, or put them back. Sources that have their own mute stay muted.
    @discardableResult
    public static func setFolderMuted(_ db: Database, id: Int64, muted: Bool) throws -> Folder {
        guard var f = try Folder.fetchOne(db, key: id) else { throw QueryError.notFound("Folder") }
        if muted == f.isMuted { return f }
        f.isMuted = muted
        try f.update(db)
        return f
    }

    /// DELETE /api/folders/:id. Its sources move to No Folder (FK ON DELETE SET NULL). False when not found.
    @discardableResult
    public static func deleteFolder(_ db: Database, id: Int64) throws -> Bool {
        try Folder.deleteOne(db, key: id)
    }

    /// PATCH /api/folders {order}: ids top to bottom.
    public static func reorderFolders(_ db: Database, _ ids: [Int64]) throws {
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [i, id])
        }
    }

    // MARK: Meta

    public static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    /// Sets a value, or deletes the row for nil/empty.
    public static func setMeta(_ db: Database, _ key: String, _ value: String?) throws {
        if let value, !value.isEmpty {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public static func lastRefreshAt(_ db: Database) throws -> Date? {
        try meta(db, MetaKey.lastRefreshAt).flatMap(ISO8601.date(from:))
    }

    public static func setLastRefreshAt(_ db: Database, _ date: Date) throws {
        try setMeta(db, MetaKey.lastRefreshAt, ISO8601.string(from: date))
    }

    // MARK: OPML import (POST /api/opml)

    /// Lookup key for "already subscribed": scheme, `www.`, trailing slash and host case don't matter.
    public static func feedKey(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^https?://(www\.)?"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        while s.hasSuffix("/") { s.removeLast() }
        if let end = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = s[s.startIndex..<end].lowercased() + s[end...]
        } else {
            s = s.lowercased()
        }
        return s
    }

    /// Source columns for an OPML feed, without fetching (opml route `sourceFields`).
    public static func opmlSourceFields(_ o: OPMLSource) throws -> DetectedFeed {
        let feedString = try SourceURL.normalize(o.feedUrl)
        guard let feed = URLComponents(string: feedString), let host = feed.host else { throw SourceURLError.invalid }
        let site = o.htmlUrl.flatMap { try? SourceURL.normalize($0) }
        let lowerHost = host.lowercased()
        let isYoutube = (lowerHost == "youtube.com" || lowerHost.hasSuffix(".youtube.com")) && feed.path.hasPrefix("/feeds/videos.xml")
        if isYoutube || o.kind == .youtube {
            let channel = feed.queryItems?.first(where: { $0.name == "channel_id" })?.value
            return DetectedFeed(
                title: o.title.isEmpty ? "YouTube channel" : o.title,
                url: channel.map { "https://www.youtube.com/channel/\($0)" } ?? site ?? feedString,
                feedUrl: channel.map { "https://www.youtube.com/feeds/videos.xml?channel_id=\($0)" } ?? feedString,
                kind: .youtube, group: SourceGroup.youtube)
        }
        let kind: SourceKind = (o.kind == .page || o.kind == .podcast) ? (o.kind ?? .rss) : .rss
        var origin = "\(feed.scheme ?? "https")://\(lowerHost)"
        if let port = feed.port { origin += ":\(port)" }
        let bareHost = lowerHost.hasPrefix("www.") ? String(lowerHost.dropFirst(4)) : lowerHost
        return DetectedFeed(
            title: o.title.isEmpty ? bareHost : o.title,
            url: kind == .page ? feedString : (site ?? origin),
            feedUrl: feedString,
            kind: kind,
            group: kind == .podcast ? SourceGroup.podcast : SourceGroup.blogs)
    }

    /// Import an OPML document: feeds already subscribed are skipped; folders are matched by title
    /// (any case) or created. Nothing is fetched; the next refresh picks the new sources up.
    public static func importOPML(_ db: Database, _ doc: OPMLDocument, now: Date = Date()) throws -> OPMLImportResult {
        var known = Set(try String.fetchAll(db, sql: "SELECT feed_url FROM sources").map(feedKey))
        let existingFolders = try folders(db)
        var folderIds: [String: Int64] = [:]
        for f in existingFolders where folderIds[f.title.trimmingCharacters(in: .whitespaces).lowercased()] == nil {
            folderIds[f.title.trimmingCharacters(in: .whitespaces).lowercased()] = f.id
        }
        var nextFolderPos = (existingFolders.map(\.position).max() ?? -1) + 1
        var result = OPMLImportResult()
        var positions: [Int64?: Int] = [:]
        func nextPosition(_ folderId: Int64?) throws -> Int {
            let p = try positions[folderId] ?? nextSourcePosition(db, folderId: folderId)
            positions[folderId] = p + 1
            return p
        }
        let groups: [(String?, [OPMLSource])] = [(nil, doc.unfiled)] + doc.folders.map { ($0.title, $0.sources) }
        for (folderTitle, list) in groups {
            var fresh: [DetectedFeed] = []
            for o in list {
                let fields: DetectedFeed
                do {
                    fields = try opmlSourceFields(o)
                } catch {
                    result.errors.append("\(o.title.isEmpty ? o.feedUrl : o.title): \(HTTP.message(error))")
                    continue
                }
                let key = feedKey(fields.feedUrl)
                if known.contains(key) {
                    result.skipped += 1
                    continue
                }
                known.insert(key)
                fresh.append(fields)
            }
            if fresh.isEmpty { continue }
            var folderId: Int64?
            if let folderTitle {
                let key = folderTitle.trimmingCharacters(in: .whitespaces).lowercased()
                if let id = folderIds[key] {
                    folderId = id
                } else {
                    var f = Folder(title: folderTitle.trimmingCharacters(in: .whitespaces), position: nextFolderPos, createdAt: now)
                    nextFolderPos += 1
                    try f.insert(db)
                    folderIds[key] = f.id
                    folderId = f.id
                    result.foldersCreated += 1
                }
            }
            for f in fresh {
                var s = Source(title: f.title, url: f.url, feedUrl: f.feedUrl, kind: f.kind, group: f.group,
                               folderId: folderId, position: try nextPosition(folderId), createdAt: now)
                // The unique feed_url constraint is the backstop for exact duplicates feedKey didn't catch.
                if try source(db, feedUrl: f.feedUrl) != nil {
                    result.skipped += 1
                    continue
                }
                try s.insert(db)
                result.added += 1
            }
        }
        return result
    }
}
