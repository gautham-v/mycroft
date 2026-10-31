import Foundation

/// One source's outcome in a refresh.
public struct SourceRefreshResult: Sendable, Hashable {
    public var sourceId: Int64
    public var title: String
    public var ok: Bool
    public var added: Int
    public var error: String?

    public init(sourceId: Int64, title: String, ok: Bool, added: Int, error: String? = nil) {
        self.sourceId = sourceId
        self.title = title
        self.ok = ok
        self.added = added
        self.error = error
    }
}

/// Port of `RefreshResult` (types.ts).
public struct RefreshResult: Sendable, Hashable {
    /// false when skipped because the last refresh is fresh (< 15 min) and force was false.
    public var ran: Bool
    public var lastRefreshAt: Date?
    public var results: [SourceRefreshResult]
    public var pruned: Int

    public init(ran: Bool, lastRefreshAt: Date?, results: [SourceRefreshResult] = [], pruned: Int = 0) {
        self.ran = ran
        self.lastRefreshAt = lastRefreshAt
        self.results = results
        self.pruned = pruned
    }
}

/// Feed fetching (port of src/lib/fetcher.ts + dedupe.ts). Owner: Fetching agent.
/// Implementation: `DefaultRefreshService` in Fetching/DefaultRefreshService.swift
/// (keep the type name and `init(database: AppDatabase, parser: any FeedParser, scraper: any PageScraper)`).
public protocol RefreshService: Sendable {
    /// refreshAll({force}): no-op (ran = false) unless forced or last_refresh_at is older than 15 min.
    /// Claims the slot (sets last_refresh_at) first, fetches every source concurrently (15 s timeout each),
    /// upserts items, records per-source errors, backfills thumbnails, then prunes old unsaved items.
    func refreshAll(force: Bool) async throws -> RefreshResult

    /// Fetches the sources never fetched on this device, whatever the stale rule says: iCloud brings a source without its
    /// items, and it may come while a refresh that has already read its sources is running. Reports `.sourceFinished` for each;
    /// a source whose fetch fails still counts as fetched, with its error recorded.
    @discardableResult
    func refreshUnfetched(progress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> [SourceRefreshResult]

    /// refreshSource(src): fetch one source now (used right after adding one). Returns items added.
    /// Records last_fetched_at / last_error on the source; rethrows the fetch error.
    @discardableResult func refreshSource(id: Int64) async throws -> Int
}
