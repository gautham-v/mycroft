import Foundation
import GRDB

/// Fetches a feed body. `timeout` is the whole request's deadline.
typealias RefreshFeedFetch = @Sendable (_ url: String, _ timeout: TimeInterval) async throws -> Data

/// Port of src/lib/fetcher.ts (refreshAll / refreshSource / backfillThumbnails) and the refresh route.
public struct DefaultRefreshService: RefreshService, RefreshProgressReporting {
    // fetcher.ts constants
    public static let feedTimeout: TimeInterval = 15
    /// Scraped-page sources remember this many handled article URLs.
    public static let maxSeenURLs = 300
    /// New items without a feed thumbnail whose page is read for og:image in the refresh that adds them.
    public static let newThumbCap = 12
    /// Older items without a thumbnail, never tried before, read per source per refresh.
    public static let oldThumbCap = 10
    public static let thumbConcurrency = 4
    /// Stop starting thumbnail fetches for a source after this; the rest are picked up next refresh.
    public static let thumbBudget: TimeInterval = 20
    /// Items considered per source per refresh (`fresh.slice(0, 100)`).
    public static let maxItemsPerFetch = 100
    /// Sources fetched at once. The web started all of them; URLSession caps per-host connections anyway.
    public static let sourceConcurrency = 12

    let database: AppDatabase
    let parser: any FeedParser
    let scraper: any PageScraper
    let fetch: RefreshFeedFetch
    let fallbacks: [String: [String]]
    let feedTimeout: TimeInterval
    let concurrency: Int

    public init(database: AppDatabase, parser: any FeedParser, scraper: any PageScraper) {
        self.init(database: database, parser: parser, scraper: scraper, fetch: Self.liveFetch)
    }

    /// Tests: inject the feed transport, fallbacks, timeout and concurrency.
    init(
        database: AppDatabase, parser: any FeedParser, scraper: any PageScraper, fetch: @escaping RefreshFeedFetch,
        fallbacks: [String: [String]] = Seed.feedFallbacks, feedTimeout: TimeInterval = Self.feedTimeout,
        concurrency: Int = Self.sourceConcurrency
    ) {
        self.database = database
        self.parser = parser
        self.scraper = scraper
        self.fetch = fetch
        self.fallbacks = fallbacks
        self.feedTimeout = feedTimeout
        self.concurrency = max(1, concurrency)
    }

    /// fetchFeedText: GET with the feed Accept header; non-2xx throws "HTTP <status>".
    static let liveFetch: RefreshFeedFetch = { url, timeout in
        try await HTTP.fetchOK(url, timeout: timeout, headers: ["Accept": HTTP.feedAccept]).data
    }

    // MARK: RefreshService

    public func refreshAll(force: Bool) async throws -> RefreshResult {
        try await refreshAll(force: force, progress: { _ in })
    }

    /// Refresh all sources if stale (> 15 min) or forced.
    public func refreshAll(force: Bool, progress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> RefreshResult {
        let now = Date()
        // Check and claim the refresh slot in one transaction so concurrent calls don't stampede.
        let claim: (ran: Bool, last: Date?) = try await database.writer.write { db in
            let last = try Queries.lastRefreshAt(db)
            if !force && !RelativeTime.isStale(last, now: now) { return (false, last) }
            try Queries.setLastRefreshAt(db, now)
            return (true, now)
        }
        guard claim.ran else {
            let r = RefreshResult(ran: false, lastRefreshAt: claim.last)
            progress(.finished(r))
            return r
        }

        let all = try await database.reader.read { try Queries.sources($0) }
        progress(.started(at: now, total: all.count))

        var results = [SourceRefreshResult?](repeating: nil, count: all.count)
        await withTaskGroup(of: (Int, SourceRefreshResult).self) { group in
            var next = 0
            func startNext() {
                guard next < all.count else { return }
                let i = next, src = all[i]
                next += 1
                group.addTask {
                    do {
                        let added = try await self.refresh(src)
                        return (i, SourceRefreshResult(sourceId: src.id, title: src.title, ok: true, added: added))
                    } catch {
                        return (i, SourceRefreshResult(sourceId: src.id, title: src.title, ok: false, added: 0, error: HTTP.message(error)))
                    }
                }
            }
            for _ in 0..<min(concurrency, all.count) { startNext() }
            var completed = 0
            while let (i, r) = await group.next() {
                results[i] = r
                completed += 1
                progress(.sourceFinished(r, completed: completed, total: all.count))
                startNext()
            }
        }

        let pruned = try await database.pruneOldItems()
        let result = RefreshResult(ran: true, lastRefreshAt: now, results: results.compactMap { $0 }, pruned: pruned)
        progress(.finished(result))
        return result
    }

    @discardableResult
    public func refreshSource(id: Int64) async throws -> Int {
        guard let src = try await database.source(id: id) else { throw QueryError.notFound("Source") }
        return try await refresh(src)
    }

    // MARK: One source

    /// refreshSource(src): fetch, dedupe, upsert, record the attempt, then backfill thumbnails. Returns items
    /// added. On failure records last_error and rethrows.
    func refresh(_ src: Source) async throws -> Int {
        do {
            let stored = try await database.reader.read { try Queries.storedItemKeys($0, sourceId: src.id) }
            let (parsed, update) = try await sourceItems(src, stored: stored)
            // Skip items already past the retention window so pruned rows don't come back.
            let cutoff = Retention.cutoff()
            let fresh = parsed.filter { $0.publishedAt >= cutoff }
            // By guid, then by link: a second HN submission of a stored story is skipped.
            let unique = FeedDedupe.dedupe(
                Array(fresh.prefix(Self.maxItemsPerFetch)), stored: stored,
                linkOnly: src.group == SourceGroup.aggregator || fresh.contains { $0.hnCommentsUrl != nil },
                siteURL: src.url)
            let rows = try await database.writer.write { db in
                let rows = try Queries.upsertItems(db, sourceId: src.id, items: unique)
                try Queries.markSourceFetched(db, sourceId: src.id, at: Date(), error: nil, update: update)
                return rows
            }
            // Page sources get og:image while scraping; YouTube thumbnails come from the video id. Podcast
            // episodes take the episode or show art from the feed, so only art-less ones reach the page.
            if src.kind == .rss || src.kind == .podcast {
                _ = try? await backfillThumbnails(sourceId: src.id, fresh: Self.newThumbTargets(rows))
            }
            return rows.filter(\.inserted).count
        } catch {
            let message = HTTP.message(error)
            try? await database.writer.write { db in
                try Queries.markSourceFetched(db, sourceId: src.id, at: Date(), error: message)
            }
            throw error
        }
    }

    /// sourceItems: scraped items for page sources (and the updated seen_urls), feed items otherwise, with
    /// first-fetch podcast promotion.
    func sourceItems(_ src: Source, stored: [StoredItemKey]) async throws -> (items: [ParsedItem], update: SourceFetchUpdate) {
        if src.kind == .page {
            // Fetch only article pages not handled before: stored items plus `seen_urls` (too old to keep, or not articles).
            let seen = src.seenUrls ?? []
            let r = try await scraper.scrape(listingURL: src.feedUrl, known: Set(seen).union(stored.map(\.url)), budget: nil)
            var seenSet = Set<String>()
            let seenUrls = (r.processed + seen).filter { seenSet.insert($0).inserted }.prefix(Self.maxSeenURLs)
            return (r.items, SourceFetchUpdate(seenUrls: Array(seenUrls)))
        }
        let feed = try await fetchSourceFeed(src)
        // OPML imports aren't fetched when added, so they start as rss without art. On the first fetch a
        // feed that turns out to be a podcast becomes one, with its show art, as if added by URL.
        let firstFetch = src.lastFetchedAt == nil && feed.isPodcast
        if firstFetch && (src.kind == .rss || (src.kind == .podcast && src.iconUrl == nil)) {
            return (feed.items, SourceFetchUpdate(kind: .podcast, group: SourceGroup.podcast, iconUrl: src.iconUrl ?? feed.imageUrl))
        }
        return (feed.items, SourceFetchUpdate())
    }

    /// fetchSourceFeed: the feed URL, then any `Seed.feedFallbacks`; the last error is thrown.
    func fetchSourceFeed(_ src: Source) async throws -> ParsedFeed {
        let candidates = [src.feedUrl] + (fallbacks[src.feedUrl] ?? [])
        var lastError: any Error = HTTPError.invalidURL(src.feedUrl)
        for url in candidates {
            do {
                let data = try await Self.withDeadline(feedTimeout) { [fetch, feedTimeout] in try await fetch(url, feedTimeout) }
                return try parser.parse(data, kind: src.kind, feedURL: url)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Thumbnails

    /// newThumbTargets: items this refresh inserted that still lack a thumbnail, newest first, at most `cap`.
    static func newThumbTargets(_ rows: [UpsertedItem], cap: Int = newThumbCap) -> [ThumbnailTarget] {
        rows.filter { $0.inserted && $0.thumbnailUrl == nil }
            .enumerated()
            .sorted { a, b in
                a.element.publishedAt != b.element.publishedAt ? a.element.publishedAt > b.element.publishedAt : a.offset < b.offset
            }
            .prefix(cap)
            .map { ThumbnailTarget(id: $0.element.id, url: $0.element.url) }
    }

    /// backfillThumbnails: fill missing thumbnails from each article's og:image. Tries this refresh's new
    /// items, then up to `oldThumbCap` older ones never tried, and marks each tried item `thumbnail_checked`.
    /// Temporary misses (429, 5xx) and items the budget didn't reach stay unmarked. Returns thumbnails found.
    @discardableResult
    func backfillThumbnails(sourceId: Int64, fresh: [ThumbnailTarget]) async throws -> Int {
        let old = try await database.reader.read { db in
            try Queries.thumbnailCandidates(db, sourceId: sourceId, excluding: fresh.map(\.id), limit: Self.oldThumbCap)
        }
        let targets = fresh + old
        guard !targets.isEmpty else { return 0 }
        let results = await scraper.fetchPageImages(
            targets, concurrency: Self.thumbConcurrency, timeout: PageMeta.thumbTimeout, budget: Self.thumbBudget)
        let found = results.compactMap { r in r.result.image.map { (r.target.id, $0) } }
        let misses = results.filter { $0.result.image == nil && $0.result.final }.map(\.target.id)
        try await database.writer.write { db in
            // setThumbnailFound only writes when thumbnail_url is still NULL (the reader may have set the lead image).
            for (id, image) in found { try Queries.setThumbnailFound(db, itemId: id, url: image) }
            try Queries.markThumbnailChecked(db, itemIds: misses)
        }
        return found.count
    }

    // MARK: Helpers

    /// Runs `op` with an overall deadline (fetchWithTimeout's AbortController); throws HTTPError.timedOut.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw HTTPError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw HTTPError.timedOut }
            return first
        }
    }
}
