import Foundation
import GRDB

/// Highlight queries. Synchronous building blocks like the rest of `Queries`; AppDatabase+Highlights.swift
/// has the async wrappers.
extension Queries {

    /// An article's highlights in the order they were made.
    public static func highlights(_ db: Database, sourceFeedUrl: String, itemGuid: String) throws -> [Highlight] {
        try Highlight
            .filter(Highlight.Columns.sourceFeedUrl == sourceFeedUrl && Highlight.Columns.itemGuid == itemGuid)
            .order(Highlight.Columns.createdAt, Column.rowID)
            .fetchAll(db)
    }

    public static func highlight(_ db: Database, id: String) throws -> Highlight? {
        try Highlight.fetchOne(db, key: id)
    }

    /// Every highlight grouped by article, the article with the newest highlight activity first;
    /// within an article, in the order they were made.
    public static func highlightGroups(_ db: Database) throws -> [HighlightGroup] {
        let all = try Highlight.order(Highlight.Columns.createdAt, Column.rowID).fetchAll(db)
        var order: [String] = []
        var byArticle: [String: HighlightGroup] = [:]
        for h in all {
            let key = h.articleKey
            if byArticle[key] == nil {
                order.append(key)
                byArticle[key] = HighlightGroup(sourceFeedUrl: h.sourceFeedUrl, itemGuid: h.itemGuid, highlights: [])
            }
            byArticle[key]?.highlights.append(h)
        }
        return order.compactMap { byArticle[$0] }.sorted { $0.activityAt > $1.activityAt }
    }

    public static func highlightCount(_ db: Database) throws -> Int {
        try Highlight.fetchCount(db)
    }

    /// Add a highlight made on this device. `forReadwise` queues it for sending.
    @discardableResult
    public static func insertHighlight(_ db: Database, _ highlight: Highlight, forReadwise: Bool = false) throws -> Highlight {
        var h = highlight
        h.readwisePending = forReadwise
        try h.insert(db)
        return h
    }

    /// Change a highlight's color and/or note (the edits the UI offers; the quote never changes).
    /// Bumps `updated_at`. Returns nil when it is gone.
    @discardableResult
    public static func updateHighlight(
        _ db: Database, id: String, color: HighlightColor? = nil, note: String? = nil,
        forReadwise: Bool = false, now: Date = Date()
    ) throws -> Highlight? {
        guard var h = try Highlight.fetchOne(db, key: id) else { return nil }
        let newNote = note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? h.note
        let newColor = color ?? h.color
        guard newNote != h.note || newColor != h.color else { return h }
        h.note = newNote
        h.color = newColor
        h.updatedAt = max(now, h.updatedAt)
        if forReadwise { h.readwisePending = true }
        try h.update(db)
        return h
    }

    /// Remove a highlight made on this device. When it had been sent to Readwise and `forReadwise` is set,
    /// its Readwise id is queued for deletion there.
    @discardableResult
    public static func deleteHighlight(_ db: Database, id: String, forReadwise: Bool = false) throws -> Bool {
        guard let h = try Highlight.fetchOne(db, key: id) else { return false }
        try h.delete(db)
        if forReadwise, let rid = h.readwiseId {
            try db.execute(sql: "INSERT OR IGNORE INTO readwise_deletes (readwise_id) VALUES (?)", arguments: [rid])
        }
        return true
    }

    // MARK: Readwise bookkeeping

    /// Highlights changed on this device that Readwise hasn't seen yet, oldest change first.
    public static func pendingReadwiseHighlights(_ db: Database) throws -> [Highlight] {
        try Highlight.filter(Highlight.Columns.readwisePending == true).order(Highlight.Columns.updatedAt, Column.rowID).fetchAll(db)
    }

    /// Readwise ids of highlights removed here and still to be deleted there.
    public static func pendingReadwiseDeletes(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT readwise_id FROM readwise_deletes ORDER BY readwise_id")
    }

    public static func clearReadwiseDelete(_ db: Database, readwiseId: Int64) throws {
        try db.execute(sql: "DELETE FROM readwise_deletes WHERE readwise_id = ?", arguments: [readwiseId])
    }

    /// Record that `sent` reached Readwise. The pending flag is cleared only if the highlight hasn't been
    /// edited since it was read, so an edit made while the request was in flight is sent next time.
    public static func markReadwiseSent(_ db: Database, sent: Highlight, readwiseId: Int64?) throws {
        try db.execute(sql: """
            UPDATE highlights SET readwise_id = coalesce(?, readwise_id),
              readwise_pending = CASE WHEN updated_at = ? THEN 0 ELSE readwise_pending END
            WHERE id = ?
            """, arguments: [readwiseId, sent.updatedAt, sent.id])
    }

    /// Readwise no longer has this highlight (a 404 on update): forget the id so the next send creates it again.
    public static func clearReadwiseId(_ db: Database, id: String) throws {
        try db.execute(sql: "UPDATE highlights SET readwise_id = NULL, readwise_pending = 1 WHERE id = ?", arguments: [id])
    }

    // MARK: Opening a highlighted article

    /// The article a group of highlights came from, as a list item, adding the item to the database from
    /// the highlights' own data when only its source is here (the item was pruned on this device, or the
    /// highlight arrived from another). nil when the source isn't on this device either.
    public static func itemForHighlights(_ db: Database, sourceFeedUrl: String, itemGuid: String) throws -> FeedItem? {
        guard let source = try sourceCreatingOpenedLinks(db, feedUrl: sourceFeedUrl) else { return nil }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE source_id = ? AND guid = ?", arguments: [source.id, itemGuid]) {
            return try feedItem(db, id: id)
        }
        guard let h = try highlights(db, sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid).last else { return nil }
        var item = Item(
            sourceId: source.id, guid: itemGuid, url: h.itemUrl, title: h.itemTitle, author: h.itemAuthor,
            publishedAt: h.itemPublishedAt ?? h.createdAt)
        try item.insert(db)
        return try feedItem(db, id: item.id)
    }
}
