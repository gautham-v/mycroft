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
    /// kept (the identity is the reserved feed URL). Unsaved items that no longer match the keyword or leave-out words
    /// are removed; the others stay until retention prunes them. Throws `notFound` for an unknown id and
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
        let matcher = TopicMatcher(o)
        // Highlighted items stay, as in retention. The host counts like it did when the search stored the item.
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title, summary, url FROM items WHERE source_id = ? AND is_saved = 0 AND NOT EXISTS (
              SELECT 1 FROM highlights h WHERE h.source_feed_url = ? AND h.item_guid = items.guid)
            """, arguments: [id, s.feedUrl])
        let stale = rows.filter { row in
            let url: String = row["url"]
            let host = URLHost.host(of: url)
            return !matcher.matches(title: row["title"], summary: row["summary"], host: host == "news.ycombinator.com" ? nil : host)
        }.map { $0["id"] as Int64 }
        for chunk in stride(from: 0, to: stale.count, by: 500).map({ Array(stale[$0..<min($0 + 500, stale.count)]) }) {
            try db.execute(sql: "DELETE FROM items WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))", arguments: StatementArguments(chunk))
        }
        return s
    }

    /// Stop following a topic and delete its items (saved ones too, like removing a source). False when it isn't a topic here.
    @discardableResult
    public static func deleteTopic(_ db: Database, id: Int64) throws -> Bool {
        guard let s = try Source.fetchOne(db, key: id), s.isTopic else { return false }
        return try deleteSource(db, id: id)
    }

    // MARK: Unread

    /// Unread items per source id, counting the source's own items only (for a topic that is what it stored, not the
    /// subscription items its list adds). An item is read once History has a read mark for it. Sources with none
    /// unread have no entry.
    public static func unreadCounts(_ db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.source_id AS id, COUNT(*) AS n FROM items i JOIN sources s ON s.id = i.source_id
            WHERE NOT EXISTS (
              SELECT 1 FROM history h WHERE h.source_feed_url = s.feed_url AND h.item_guid = i.guid AND h.read_at IS NOT NULL)
            GROUP BY i.source_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["n"] as Int) })
    }

    // MARK: Item filter

    /// The WHERE condition behind a topic's chips; nil for `.all`.
    static func topicFilterCondition(_ filter: TopicContentFilter) -> SQLExpression? {
        let video = Item.Columns.videoId, audio = Item.Columns.audioUrl, comments = Item.Columns.hnCommentsUrl
        let reddit = SQL("(\(Item.Columns.url) LIKE '%reddit.com/%/comments/%')").sqlExpression
        switch filter {
        case .all: return nil
        case .videos: return video != nil
        case .episodes: return video == nil && audio != nil
        case .discussions: return video == nil && audio == nil && (comments != nil || reddit)
        case .articles: return video == nil && audio == nil && comments == nil && !reddit
        }
    }
}
