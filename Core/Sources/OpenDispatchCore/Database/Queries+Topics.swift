import Foundation
import GRDB

/// Topics (followed keyword searches) and unread counts. A topic is a row of `sources` with kind `topic`, so
/// refresh, notifications, Mark All as Read, Saved, History and retention treat it like any source; the
/// functions here are what differs.
extension Queries {

    // MARK: Lists

    /// Topics in sidebar order: creation order (position), then keyword.
    public static func topics(_ db: Database) throws -> [Source] {
        try Source
            .filter(Source.Columns.kind == SourceKind.topic.rawValue)
            .order(Source.Columns.position, Source.Columns.title, Source.Columns.id)
            .fetchAll(db)
    }

    /// Everything the user subscribes to: `sources` without topics. The sidebar tree, the Sources lists, the
    /// OPML export and the add-source duplicate check read this.
    public static func subscriptions(_ db: Database) throws -> [Source] {
        try Source
            .filter(!OpenedLinks.feedURLs.contains(Source.Columns.feedUrl))
            .filter(Source.Columns.kind != SourceKind.topic.rawValue)
            .order(Source.Columns.position, Source.Columns.title)
            .fetchAll(db)
    }

    /// The topic whose keyword is `keyword` (ignoring case, diacritics and extra spaces), for Explore's Follow / Following.
    public static func topic(_ db: Database, keyword: String) throws -> Source? {
        let wanted = TopicMatcher.fold(keyword.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard !wanted.isEmpty else { return nil }
        return try topics(db).first { t in
            TopicMatcher.fold((t.topicOptions?.keyword ?? t.title).split(whereSeparator: \.isWhitespace).joined(separator: " ")) == wanted
        }
    }

    // MARK: Create, edit, delete

    /// Follow a keyword. A topic with the same keyword already followed is returned as it is (nothing is changed), so
    /// Follow twice is one topic. It lands last in the list. Throws `QueryError.invalid` for a blank keyword.
    @discardableResult
    public static func createTopic(_ db: Database, options: TopicOptions, now: Date = Date()) throws -> Source {
        let o = options.cleaned
        guard !o.keyword.isEmpty else { throw QueryError.invalid("keyword is required") }
        if let existing = try topic(db, keyword: o.keyword) { return existing }
        let last = try Int.fetchOne(db, sql: "SELECT max(position) FROM sources WHERE kind = ?", arguments: [SourceKind.topic.rawValue])
        var s = Source(
            title: o.keyword, url: Topic.siteURL, feedUrl: Topic.newFeedURL(), kind: .topic, group: SourceGroup.topics,
            position: (last ?? -1) + 1, createdAt: now, topicOptions: o)
        try s.insert(db)
        return s
    }

    /// Change what a topic follows. The title follows the keyword; items, saved items, History and sync records are
    /// kept (the identity is the reserved feed URL). When the keyword or the leave-out words changed, unsaved and unhighlighted
    /// items that no longer match are removed; the others stay until a refresh applies the other rules
    /// (`removeStaleTopicItems`) or retention prunes them. Throws `notFound` for an unknown id and
    /// `invalid` for a blank keyword or a source that isn't a topic.
    @discardableResult
    public static func updateTopic(_ db: Database, id: Int64, options: TopicOptions) throws -> Source {
        let o = options.cleaned
        guard !o.keyword.isEmpty else { throw QueryError.invalid("keyword is required") }
        guard var s = try Source.fetchOne(db, key: id) else { throw QueryError.notFound("Topic") }
        guard s.isTopic else { throw QueryError.invalid("Not a topic") }
        let before = s.topicOptions
        s.title = o.keyword
        s.topicOptions = o
        try s.update(db)
        // What matches is decided by the keyword and the leave-out words alone, so other edits (notify, places, Show)
        // can't turn a stored item into a non-match.
        guard before?.keyword != o.keyword || before?.excluded != o.excluded else { return s }
        try removeStaleTopicItems(db, topic: s, languages: nil, checkPlaces: false)
        return s
    }

    /// Remove a topic's stored items that its current rules would not store: the keyword not in the title, a leave-out word in the
    /// title or summary, a place now turned off (Reddit, say), a paywalled site when those are skipped, and with `languages` a
    /// title in a language the user doesn't read. Saved and highlighted items stay. Stories left without their lead pass to
    /// their next article. Returns how many items were removed.
    @discardableResult
    static func removeStaleTopicItems(_ db: Database, topic: Source, languages: TopicLanguages?, checkPlaces: Bool = true) throws -> Int {
        guard let options = topic.topicOptions else { return 0 }
        let matcher = TopicMatcher(options)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, guid, url, title, summary, author, video_id, audio_url FROM items WHERE source_id = ? AND is_saved = 0 AND NOT EXISTS (
              SELECT 1 FROM highlights h WHERE h.source_feed_url = ? AND h.item_guid = items.guid)
            """, arguments: [topic.id, topic.feedUrl])
        let stale = rows.filter { row in
            let title: String = row["title"]
            let place = Topic.place(guid: row["guid"], videoId: row["video_id"], audioUrl: row["audio_url"])
            if checkPlaces, !options.places.isSearched(place) { return true }
            if place.matchesText ? !matcher.matches(title: title, summary: row["summary"]) : !matcher.matchesTitle(title, summary: row["summary"]) { return true }
            if let languages, languages.rejects(title) { return true }
            if checkPlaces, place == .news, options.skipPaywalled {
                let url: String = row["url"]
                let author: String? = row["author"]
                if TopicPaywalls.isPaywalled(url) || author.map(TopicPaywalls.isPaywalled(publisher:)) == true { return true }
            }
            return false
        }.map { $0["id"] as Int64 }
        var readLeads = Set<Int64>()
        let chunks = stride(from: 0, to: stale.count, by: 500).map { Array(stale[$0..<min($0 + 500, stale.count)]) }
        for chunk in chunks {
            let ids = "id IN (\(databaseQuestionMarks(count: chunk.count)))"
            readLeads.formUnion(try readStoryLeads(db, where: ids, arguments: StatementArguments(chunk)))
            try db.execute(sql: "DELETE FROM items WHERE \(ids)", arguments: StatementArguments(chunk))
        }
        if !stale.isEmpty { try repairStories(db, readLeads: readLeads) }
        return stale.count
    }

    /// Stop following a topic and delete its items (saved ones too, like removing a source). False when it isn't a topic here.
    @discardableResult
    public static func deleteTopic(_ db: Database, id: Int64) throws -> Bool {
        guard let s = try Source.fetchOne(db, key: id), s.isTopic else { return false }
        return try deleteSource(db, id: id)
    }

    // MARK: Unread

    /// Unread items per source id, counting the source's own items only (for a topic that is what it stored, not the
    /// subscription items its list adds). An item is read once History has a read mark for it. A topic counts a news story once,
    /// by its lead: the other outlets' articles and the Hacker News thread behind it don't add to the count. Sources with none
    /// unread have no entry.
    public static func unreadCounts(_ db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.source_id AS id, COUNT(*) AS n FROM items i JOIN sources s ON s.id = i.source_id
            WHERE i.story_id IS NULL AND NOT EXISTS (
              SELECT 1 FROM history h WHERE h.source_feed_url = s.feed_url AND h.item_guid = i.guid AND h.read_at IS NOT NULL)
            GROUP BY i.source_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["n"] as Int) })
    }

    // MARK: Item filter

    /// How many rows each filter of a topic's list shows (a story is one row), for the title menu. Counts what the list lists,
    /// the user's own matching items included when the topic shows them.
    public static func topicFilterCounts(_ db: Database, topicId: Int64) throws -> [TopicContentFilter: Int] {
        var out: [TopicContentFilter: Int] = [:]
        for filter in TopicContentFilter.allCases {
            let src = TableAlias<Source>()
            var req = Item.joining(required: Item.source.aliased(src))
            let topic = try topicScope(db, ItemQuery(sourceId: topicId))
            for cond in conditions(ItemQuery(sourceId: topicId, topicFilter: filter), src: src, topic: topic) { req = req.filter(cond) }
            out[filter] = try req.fetchCount(db)
        }
        return out
    }

    /// The WHERE condition behind a topic's filters; nil for `.all`.
    static func topicFilterCondition(_ filter: TopicContentFilter) -> SQLExpression? {
        let video = Item.Columns.videoId, audio = Item.Columns.audioUrl, comments = Item.Columns.hnCommentsUrl
        let reddit = SQL("(\(Item.Columns.url) LIKE '%reddit.com/%/comments/%')").sqlExpression
        let social = SQL("(\(Item.Columns.url) LIKE 'https://x.com/%/status/%' OR \(Item.Columns.url) LIKE 'https://bsky.app/profile/%/post/%')").sqlExpression
        switch filter {
        case .all: return nil
        case .videos: return video != nil
        case .episodes: return video == nil && audio != nil
        case .discussions: return video == nil && audio == nil && !social && (comments != nil || reddit)
        case .posts: return video == nil && audio == nil && social
        case .news: return video == nil && audio == nil && comments == nil && !reddit && !social
        }
    }
}
