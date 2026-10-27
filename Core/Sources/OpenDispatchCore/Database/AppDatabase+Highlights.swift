import Foundation
import GRDB

/// Async wrappers over the highlight queries for UI code. `forReadwise` says the change was made by the
/// user on this device while "Send highlights to Readwise" is on; synced changes never set it.
extension AppDatabase {

    public func highlights(sourceFeedUrl: String, itemGuid: String) async throws -> [Highlight] {
        try await reader.read { db in try Queries.highlights(db, sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }
    }

    public func highlightGroups() async throws -> [HighlightGroup] {
        try await reader.read { db in try Queries.highlightGroups(db) }
    }

    public func highlightCount() async throws -> Int {
        try await reader.read { db in try Queries.highlightCount(db) }
    }

    @discardableResult
    public func insertHighlight(_ highlight: Highlight, forReadwise: Bool = false) async throws -> Highlight {
        try await writer.write { db in try Queries.insertHighlight(db, highlight, forReadwise: forReadwise) }
    }

    @discardableResult
    public func updateHighlight(id: String, color: HighlightColor? = nil, note: String? = nil, forReadwise: Bool = false) async throws -> Highlight? {
        try await writer.write { db in try Queries.updateHighlight(db, id: id, color: color, note: note, forReadwise: forReadwise) }
    }

    @discardableResult
    public func deleteHighlight(id: String, forReadwise: Bool = false) async throws -> Bool {
        try await writer.write { db in try Queries.deleteHighlight(db, id: id, forReadwise: forReadwise) }
    }

    public func itemForHighlights(sourceFeedUrl: String, itemGuid: String) async throws -> FeedItem? {
        try await writer.write { db in try Queries.itemForHighlights(db, sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }
    }
}
