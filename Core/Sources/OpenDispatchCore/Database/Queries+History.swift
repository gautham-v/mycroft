import Foundation
import GRDB

/// Read state and History (the `history` table). Every write takes a snapshot of the article, which a new
/// row is made from and an existing row's description is refreshed from (its title can change between
/// fetches); the read and playback fields are what each call is about.
extension Queries {

    /// Every row, the most recently opened or marked read first.
    public static func history(_ db: Database) throws -> [HistoryEntry] {
        try HistoryEntry.fetchAll(db, sql: "SELECT * FROM history ORDER BY COALESCE(opened_at, read_at) DESC, item_title")
    }

    public static func historyEntry(_ db: Database, sourceFeedUrl: String, itemGuid: String) throws -> HistoryEntry? {
        try HistoryEntry.fetchOne(db, sql: "SELECT * FROM history WHERE source_feed_url = ? AND item_guid = ?",
                                  arguments: [sourceFeedUrl, itemGuid])
    }

    /// The article was opened: it goes to the top of History, and an article or post becomes read. A video or
    /// episode becomes read only when played to the end (`recordProgress`).
    @discardableResult
    public static func recordOpen(_ db: Database, _ snapshot: HistoryEntry, isMedia: Bool, now: Date = Date()) throws -> HistoryEntry {
        var e = try existing(db, snapshot) ?? snapshot
        e.openedAt = now
        if !isMedia, e.readAt == nil { e.readAt = now }
        try e.save(db)
        return e
    }

    /// Mark as Read / Unread from a list. Read without opening adds a row History doesn't list; unread takes
    /// such a row away again, and on an opened one clears the read mark and the playback position.
    @discardableResult
    public static func setRead(_ db: Database, _ snapshot: HistoryEntry, read: Bool, now: Date = Date()) throws -> HistoryEntry? {
        let found = try existing(db, snapshot)
        if read {
            var e = found ?? snapshot
            if e.readAt == nil { e.readAt = now }
            try e.save(db)
            return e
        }
        guard var e = found else { return nil }
        if e.openedAt == nil {
            try e.delete(db)
            return nil
        }
        e.readAt = nil
        e.positionSec = nil
        try e.save(db)
        return e
    }

    /// Playback reached `position` seconds of `duration` (0 when the player doesn't know it yet). Past
    /// `HistoryEntry.finishedFraction` of the length the video or episode is read.
    @discardableResult
    public static func recordProgress(_ db: Database, _ snapshot: HistoryEntry, position: Double, duration: Double, now: Date = Date()) throws -> HistoryEntry {
        var e = try existing(db, snapshot) ?? snapshot
        if e.openedAt == nil { e.openedAt = now }
        e.positionSec = max(position, 0)
        if duration > 0 { e.durationSec = duration }
        if e.readAt == nil, let d = e.durationSec, d > 0, position >= d * HistoryEntry.finishedFraction { e.readAt = now }
        try e.save(db)
        return e
    }

    /// Remove from History: the article is unread again.
    @discardableResult
    public static func removeHistory(_ db: Database, sourceFeedUrl: String, itemGuid: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM history WHERE source_feed_url = ? AND item_guid = ?", arguments: [sourceFeedUrl, itemGuid])
        return db.changesCount > 0
    }

    /// Clear History: everything opened or marked read since `since`, or all of it (nil). Those articles are
    /// unread again. Returns rows removed.
    @discardableResult
    public static func clearHistory(_ db: Database, since: Date?) throws -> Int {
        if let since {
            try db.execute(sql: "DELETE FROM history WHERE COALESCE(opened_at, read_at) >= ?", arguments: [since])
        } else {
            try db.execute(sql: "DELETE FROM history")
        }
        return db.changesCount
    }

    /// Mark All as Read: every item the query lists (all pages), newest first. Returns how many became read.
    @discardableResult
    public static func markAllRead(_ db: Database, _ query: ItemQuery, now: Date = Date()) throws -> Int {
        var q = query
        q.limit = 200
        q.cursor = nil
        var marked = 0
        while true {
            let page = try items(db, q)
            for item in page.items {
                let before = try existing(db, HistoryEntry(item: item))
                if before?.readAt == nil {
                    try setRead(db, HistoryEntry(item: item), read: true, now: now)
                    marked += 1
                }
            }
            guard let next = page.nextCursor else { break }
            q.cursor = next
        }
        return marked
    }

    /// Rows only marked read (never opened) whose item is gone: they only ever changed how that item listed.
    @discardableResult
    static func pruneReadMarks(_ db: Database) throws -> Int {
        try db.execute(sql: """
            DELETE FROM history WHERE opened_at IS NULL AND NOT EXISTS (
              SELECT 1 FROM items i JOIN sources s ON s.id = i.source_id
              WHERE s.feed_url = history.source_feed_url AND i.guid = history.item_guid)
            """)
        return db.changesCount
    }

    /// The article an entry is about, as a list item, adding the item back from the entry's snapshot when only
    /// its source is here (pruned on this device, or read on another). nil when the source isn't here either.
    public static func itemForHistory(_ db: Database, _ entry: HistoryEntry) throws -> FeedItem? {
        guard let source = try sourceCreatingOpenedLinks(db, feedUrl: entry.sourceFeedUrl) else { return nil }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE source_id = ? AND guid = ?", arguments: [source.id, entry.itemGuid]) {
            return try feedItem(db, id: id)
        }
        var item = Item(
            sourceId: source.id, guid: entry.itemGuid, url: entry.itemUrl, title: entry.itemTitle, author: entry.itemAuthor,
            publishedAt: entry.itemPublishedAt ?? entry.activityAt ?? Date(), thumbnailUrl: entry.thumbnailUrl,
            videoId: entry.videoId, durationSec: entry.durationSec.map { Int($0) }, audioUrl: entry.audioUrl)
        try item.insert(db)
        return try feedItem(db, id: item.id)
    }

    /// The stored row for the snapshot's article with the snapshot's description, or nil.
    private static func existing(_ db: Database, _ snapshot: HistoryEntry) throws -> HistoryEntry? {
        guard var e = try historyEntry(db, sourceFeedUrl: snapshot.sourceFeedUrl, itemGuid: snapshot.itemGuid) else { return nil }
        e.itemUrl = snapshot.itemUrl
        e.itemTitle = snapshot.itemTitle
        e.sourceTitle = snapshot.sourceTitle
        e.sourceKind = snapshot.sourceKind
        e.itemAuthor = snapshot.itemAuthor ?? e.itemAuthor
        e.itemPublishedAt = snapshot.itemPublishedAt ?? e.itemPublishedAt
        e.thumbnailUrl = snapshot.thumbnailUrl ?? e.thumbnailUrl
        e.videoId = snapshot.videoId ?? e.videoId
        e.audioUrl = snapshot.audioUrl ?? e.audioUrl
        if e.durationSec == nil { e.durationSec = snapshot.durationSec }
        return e
    }
}
