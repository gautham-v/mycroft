import Foundation
import GRDB

/// A video a refresh asks YouTube about.
struct EmbedCheckTarget: Sendable, Hashable {
    var id: Int64
    var videoId: String
}

/// Videos whose owner keeps them out of other apps (`Item.embedBlocked`).
extension Queries {

    /// Hide applies to this query: it asks for it, and the list isn't Saved (kept on purpose), a search or a topic's.
    static func hidesBlockedVideos(_ q: ItemQuery, topic: Source?) -> Bool {
        q.hidesBlockedVideos && topic == nil && q.searchTerms.isEmpty && (q.view != .saved || q.sourceId != nil || q.folderId != nil)
    }

    /// How many videos the query leaves out for not playing here, over the whole list rather than a page of it.
    public static func hiddenBlockedVideoCount(_ db: Database, _ q: ItemQuery) throws -> Int {
        guard hidesBlockedVideos(q, topic: try topicScope(db, q)) else { return 0 }
        var shown = q
        shown.hidesBlockedVideos = false
        shown.cursor = nil
        let src = TableAlias<Source>()
        var req = Item.joining(required: Item.source.aliased(src)).filter(Item.Columns.embedBlocked == true)
        for cond in conditions(shown, src: src) { req = req.filter(cond) }
        return try req.fetchCount(db)
    }

    /// The player found the video won't play here, whatever a check said earlier.
    public static func setVideoBlocked(_ db: Database, itemId: Int64) throws {
        try db.execute(sql: "UPDATE items SET embed_blocked = 1 WHERE id = ?", arguments: [itemId])
    }

    /// The videos of these sources not yet known, newest first: all those stored since `storedSince`, then up to `backfill`
    /// older ones per source. The new ones lead, so a refresh short of time spends it on them.
    static func embedCheckTargets(_ db: Database, sourceIds: [Int64], storedSince: Date, backfill: Int) throws -> [EmbedCheckTarget] {
        var fresh: [(target: EmbedCheckTarget, at: Date)] = []
        var older: [(target: EmbedCheckTarget, at: Date)] = []
        for sourceId in sourceIds {
            var left = backfill
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, video_id, published_at, created_at >= ? AS is_new FROM items
                WHERE source_id = ? AND video_id IS NOT NULL AND embed_blocked IS NULL
                ORDER BY is_new DESC, published_at DESC, id DESC
                """, arguments: [storedSince, sourceId])
            while let row = try rows.next() {
                let at: Date = row["published_at"]
                let target = EmbedCheckTarget(id: row["id"], videoId: row["video_id"])
                if row["is_new"] as Bool {
                    fresh.append((target, at))
                } else if left > 0 {
                    older.append((target, at))
                    left -= 1
                } else {
                    break
                }
            }
        }
        return (fresh.sorted { $0.at > $1.at } + older.sorted { $0.at > $1.at }).map(\.target)
    }

    /// Stores what the checks found, by item id. An answer the player gave meanwhile stands.
    static func storeEmbedChecks(_ db: Database, playable: [Int64: Bool]) throws {
        for (id, plays) in playable {
            try db.execute(sql: "UPDATE items SET embed_blocked = ? WHERE id = ? AND embed_blocked IS NULL", arguments: [!plays, id])
        }
    }
}
