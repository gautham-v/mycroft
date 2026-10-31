import Foundation
import GRDB

/// What For You and "Sources for you" work from: the reading profile, suggestions, and the local record of rows seen, every
/// open, and sources removed. These tables are per device and don't sync.
extension Queries {

    // MARK: Profile

    /// Opens of each source in the last two weeks against what it published since the first of those opens (History may
    /// start later than the items do, and rows published before it had no chance to count).
    public static func readingProfile(_ db: Database, now: Date = Date()) throws -> ReadingProfile {
        let since = now.addingTimeInterval(-ReadingProfile.window)
        let opens = try Row.fetchAll(db, sql: """
            SELECT source_feed_url AS feed, COUNT(*) AS n, MIN(opened_at) AS first FROM history
            WHERE opened_at >= ? GROUP BY source_feed_url
            """, arguments: [since])
        let firstOpen: Date? = opens.compactMap { $0["first"] as Date? }.min()
        guard let firstOpen else { return .empty }
        let holders = databaseQuestionMarks(count: OpenedLinks.feedURLs.count)
        let published = try Row.fetchAll(db, sql: """
            SELECT s.feed_url AS feed, COUNT(i.id) AS n FROM sources s
            LEFT JOIN items i ON i.source_id = s.id AND i.published_at >= ?
            WHERE s.kind != 'topic' AND s.is_hidden = 0 AND s.is_muted = 0 AND s.feed_url NOT IN (\(holders))
            GROUP BY s.id
            """, arguments: StatementArguments([max(since, firstOpen)]) + StatementArguments(OpenedLinks.feedURLs))
        let opensByFeed: [String: Int] = Dictionary(opens.map { (row: Row) -> (String, Int) in (row["feed"], row["n"]) }, uniquingKeysWith: { a, _ in a })
        let publishedByFeed: [String: Int] = Dictionary(published.map { (row: Row) -> (String, Int) in (row["feed"], row["n"]) }, uniquingKeysWith: { a, _ in a })
        let totalOpens = publishedByFeed.keys.reduce(0) { $0 + (opensByFeed[$1] ?? 0) }
        let totalPublished = publishedByFeed.values.reduce(0, +)
        let overall = Double(totalOpens + 1) / Double(totalPublished + 1)
        var affinities: [String: SourceAffinity] = [:]
        for (feed, count) in publishedByFeed {
            let opened = opensByFeed[feed] ?? 0
            affinities[feed] = SourceAffinity(opens: opened, published: count, lift: ReadingProfile.lift(opens: opened, published: count, overall: overall))
        }
        return ReadingProfile(affinities: affinities)
    }

    // MARK: Suggestions

    /// How far back suggestions look through History.
    static let suggestionWindow: TimeInterval = 30 * 86_400

    /// Sources outside the library that the user's own reading points to, strongest evidence first.
    public static func sourceSuggestions(_ db: Database, now: Date = Date()) throws -> [SourceSuggestion] {
        let all = try Source.fetchAll(db)
        let topics = Set(all.filter(\.isTopic).map(\.feedUrl))
        let opened = try Row.fetchAll(db, sql: """
            SELECT h.source_feed_url AS feed, h.source_title AS title, h.item_url AS url, i.content_html AS html, i.summary AS summary
            FROM history h
            LEFT JOIN sources s ON s.feed_url = h.source_feed_url
            LEFT JOIN items i ON i.source_id = s.id AND i.guid = h.item_guid
            WHERE h.opened_at >= ?
            """, arguments: [now.addingTimeInterval(-suggestionWindow)]).map { row -> SourceSuggester.Opened in
                let feed: String = row["feed"]
                let html: String? = row["html"]
                let summary: String? = row["summary"]
                let isTopic = Topic.isTopicFeedURL(feed)
                let text = [html.map { String($0.prefix(60_000)) }, summary].compactMap { $0 }.joined(separator: " ")
                return SourceSuggester.Opened(
                    feedUrl: feed, sourceTitle: row["title"], itemUrl: row["url"], content: text.isEmpty ? nil : text,
                    topic: topics.contains(feed) ? row["title"] : nil,
                    isOutsideLibrary: isTopic || OpenedLinks.feedURLs.contains(feed))
            }
        let followed = all.filter { !$0.isTopic && !$0.isOpenedLinks }.map {
            SourceSuggester.Followed(feedUrl: $0.feedUrl, title: $0.title, host: Self.publisherHost($0))
        }
        return SourceSuggester(opened: opened, followed: followed, removed: try removedSourceKeys(db),
                               removedTitles: try String.fetchAll(db, sql: "SELECT title FROM removed_sources")).suggestions()
    }

    /// The site a source belongs to, when it has one of its own: an account on X or a community on Reddit says nothing about
    /// who else publishes on that host.
    private static func publisherHost(_ source: Source) -> String {
        let shared: Set<String> = ["x.com", "twitter.com", "reddit.com", "youtube.com", "bsky.app", "mastodon.social"]
        let host = source.host
        return shared.contains(host) ? "" : host
    }

    // MARK: Removed sources

    static func removedSourceKeys(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT feed_url FROM removed_sources").map(SourceSearch.feedKey))
    }

    /// Remember a source so it isn't suggested back: it was removed, or a suggestion for it was dismissed. Adding the source
    /// again forgets this (the `sources_forget_removal` trigger).
    public static func rememberRemovedSource(_ db: Database, feedUrl: String, title: String, now: Date = Date()) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO removed_sources (feed_url, title, removed_at) VALUES (?, ?, ?)",
                       arguments: [feedUrl, title, now])
    }

    // MARK: Rows seen and opens

    /// Rows that came on screen, each counted once however often it comes back. Rows skipped can't be worked out later, so
    /// this is recorded before anything uses it. An opened row is one the user chose from among these.
    public static func recordRowsSeen(_ db: Database, _ rows: [(feedUrl: String, guid: String)], now: Date = Date()) throws {
        for row in rows {
            try db.execute(sql: "INSERT OR IGNORE INTO rows_seen (source_feed_url, item_guid, first_seen_at) VALUES (?, ?, ?)",
                           arguments: [row.feedUrl, row.guid, now])
        }
    }

    /// `history.opened_at` keeps only the last open; this keeps them all.
    static func recordOpenEvent(_ db: Database, _ snapshot: HistoryEntry, now: Date) throws {
        try db.execute(sql: "INSERT INTO open_events (source_feed_url, item_guid, opened_at) VALUES (?, ?, ?)",
                       arguments: [snapshot.sourceFeedUrl, snapshot.itemGuid, now])
    }

    /// Clearing History clears what was learned over the same time.
    static func clearReadingSignals(_ db: Database, since: Date?) throws {
        if let since {
            try db.execute(sql: "DELETE FROM open_events WHERE opened_at >= ?", arguments: [since])
            try db.execute(sql: "DELETE FROM rows_seen WHERE first_seen_at >= ?", arguments: [since])
        } else {
            try db.execute(sql: "DELETE FROM open_events")
            try db.execute(sql: "DELETE FROM rows_seen")
        }
    }

    static func clearReadingSignals(_ db: Database, sourceFeedUrl: String, itemGuid: String) throws {
        try db.execute(sql: "DELETE FROM open_events WHERE source_feed_url = ? AND item_guid = ?", arguments: [sourceFeedUrl, itemGuid])
        try db.execute(sql: "DELETE FROM rows_seen WHERE source_feed_url = ? AND item_guid = ?", arguments: [sourceFeedUrl, itemGuid])
    }

    /// Rows seen and opens long past being useful.
    static func pruneReadingSignals(_ db: Database, before cutoff: Date) throws {
        try db.execute(sql: "DELETE FROM open_events WHERE opened_at < ?", arguments: [cutoff])
        try db.execute(sql: "DELETE FROM rows_seen WHERE first_seen_at < ?", arguments: [cutoff])
    }
}

extension AppDatabase {
    public func readingProfile() async throws -> ReadingProfile {
        try await reader.read { db in try Queries.readingProfile(db) }
    }

    public func sourceSuggestions() async throws -> [SourceSuggestion] {
        try await reader.read { db in try Queries.sourceSuggestions(db) }
    }

    public func recordRowsSeen(_ rows: [(feedUrl: String, guid: String)]) async throws {
        try await writer.write { db in try Queries.recordRowsSeen(db, rows) }
    }

    public func rememberRemovedSource(feedUrl: String, title: String) async throws {
        try await writer.write { db in try Queries.rememberRemovedSource(db, feedUrl: feedUrl, title: title) }
    }
}
