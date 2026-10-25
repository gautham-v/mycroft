import Foundation
import GRDB

/// Async wrappers over `Queries` for UI code. Each runs in its own read or write transaction.
extension AppDatabase {

    // MARK: Items

    public func items(_ query: ItemQuery) async throws -> ItemPage {
        try await reader.read { db in try Queries.items(db, query) }
    }

    public func feedItem(id: Int64) async throws -> FeedItem? {
        try await reader.read { db in try Queries.feedItem(db, id: id) }
    }

    /// Full row including content_html.
    public func itemRecord(id: Int64) async throws -> Item? {
        try await reader.read { db in try Queries.itemRecord(db, id: id) }
    }

    @discardableResult
    public func setSaved(itemId: Int64, saved: Bool) async throws -> FeedItem? {
        try await writer.write { db in try Queries.setSaved(db, itemId: itemId, saved: saved) }
    }

    public func counts() async throws -> ItemCounts {
        try await reader.read { db in try Queries.counts(db) }
    }

    public func cacheContent(itemId: Int64, result: ExtractResult) async throws {
        try await writer.write { db in try Queries.cacheContent(db, itemId: itemId, result: result) }
    }

    @discardableResult
    public func pruneOldItems(before cutoff: Date = Retention.cutoff()) async throws -> Int {
        try await writer.write { db in try Queries.pruneOldItems(db, before: cutoff) }
    }

    // MARK: Sources & folders

    /// Sources (position, title) and folders (position, id) in one read.
    public func sourcesAndFolders() async throws -> (sources: [Source], folders: [Folder]) {
        try await reader.read { db in (try Queries.sources(db), try Queries.folders(db)) }
    }

    public func sources() async throws -> [Source] {
        try await reader.read { db in try Queries.sources(db) }
    }

    public func source(id: Int64) async throws -> Source? {
        try await reader.read { db in try Queries.source(db, id: id) }
    }

    public func folders() async throws -> [Folder] {
        try await reader.read { db in try Queries.folders(db) }
    }

    public func insertSource(_ found: DetectedFeed, group: String? = nil) async throws -> (source: Source, existed: Bool) {
        try await writer.write { db in try Queries.insertSource(db, found, group: group) }
    }

    @discardableResult
    public func renameSource(id: Int64, title: String) async throws -> Source {
        try await writer.write { db in try Queries.renameSource(db, id: id, title: title) }
    }

    @discardableResult
    public func moveSource(id: Int64, toFolder folderId: Int64?) async throws -> Source {
        try await writer.write { db in try Queries.moveSource(db, id: id, toFolder: folderId) }
    }

    @discardableResult
    public func deleteSource(id: Int64) async throws -> Bool {
        try await writer.write { db in try Queries.deleteSource(db, id: id) }
    }

    public func reorderSources(_ order: [SourceOrderEntry]) async throws {
        try await writer.write { db in try Queries.reorderSources(db, order) }
    }

    /// Creates a folder at the bottom; when `withSource` is set, moves that source into it.
    @discardableResult
    public func createFolder(title: String, withSource sourceId: Int64? = nil) async throws -> Folder {
        try await writer.write { db in
            let f = try Queries.createFolder(db, title: title)
            if let sourceId { try Queries.moveSource(db, id: sourceId, toFolder: f.id) }
            return f
        }
    }

    @discardableResult
    public func renameFolder(id: Int64, title: String) async throws -> Folder {
        try await writer.write { db in try Queries.renameFolder(db, id: id, title: title) }
    }

    @discardableResult
    public func deleteFolder(id: Int64) async throws -> Bool {
        try await writer.write { db in try Queries.deleteFolder(db, id: id) }
    }

    public func reorderFolders(_ ids: [Int64]) async throws {
        try await writer.write { db in try Queries.reorderFolders(db, ids) }
    }

    public func importOPML(_ doc: OPMLDocument) async throws -> OPMLImportResult {
        try await writer.write { db in try Queries.importOPML(db, doc) }
    }

    // MARK: Meta

    public func meta(_ key: String) async throws -> String? {
        try await reader.read { db in try Queries.meta(db, key) }
    }

    public func setMeta(_ key: String, _ value: String?) async throws {
        try await writer.write { db in try Queries.setMeta(db, key, value) }
    }

    public func lastRefreshAt() async throws -> Date? {
        try await reader.read { db in try Queries.lastRefreshAt(db) }
    }

    public func setLastRefreshAt(_ date: Date) async throws {
        try await writer.write { db in try Queries.setLastRefreshAt(db, date) }
    }
}
