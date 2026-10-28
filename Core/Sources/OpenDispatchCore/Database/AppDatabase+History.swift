import Foundation
import GRDB

/// Async wrappers over the read state and History queries for UI code.
extension AppDatabase {

    public func history() async throws -> [HistoryEntry] {
        try await reader.read { db in try Queries.history(db) }
    }

    /// Every row, now and again after each change to the table, whether made here or applied from iCloud.
    public func observeHistory() -> AsyncValueObservation<[HistoryEntry]> {
        ValueObservation.tracking { db in try Queries.history(db) }.values(in: reader)
    }

    @discardableResult
    public func recordOpen(_ snapshot: HistoryEntry, isMedia: Bool) async throws -> HistoryEntry {
        try await writer.write { db in try Queries.recordOpen(db, snapshot, isMedia: isMedia) }
    }

    @discardableResult
    public func setRead(_ snapshot: HistoryEntry, read: Bool) async throws -> HistoryEntry? {
        try await writer.write { db in try Queries.setRead(db, snapshot, read: read) }
    }

    @discardableResult
    public func recordProgress(_ snapshot: HistoryEntry, position: Double, duration: Double) async throws -> HistoryEntry {
        try await writer.write { db in try Queries.recordProgress(db, snapshot, position: position, duration: duration) }
    }

    @discardableResult
    public func removeHistory(sourceFeedUrl: String, itemGuid: String) async throws -> Bool {
        try await writer.write { db in try Queries.removeHistory(db, sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }
    }

    @discardableResult
    public func clearHistory(since: Date?) async throws -> Int {
        try await writer.write { db in try Queries.clearHistory(db, since: since) }
    }

    @discardableResult
    public func markAllRead(_ query: ItemQuery) async throws -> Int {
        try await writer.write { db in try Queries.markAllRead(db, query) }
    }

    public func itemForHistory(_ entry: HistoryEntry) async throws -> FeedItem? {
        try await writer.write { db in try Queries.itemForHistory(db, entry) }
    }
}
