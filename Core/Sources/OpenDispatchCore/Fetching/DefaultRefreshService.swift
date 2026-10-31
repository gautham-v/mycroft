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
    /// Items considered per topic per refresh: up to 30 from each of the five providers.
    public static let maxTopicItemsPerFetch = 150
    /// Sources fetched at once. The web started all of them; URLSession caps per-host connections anyway.
    public static let sourceConcurrency = 12
    /// Older videos of a source not yet asked about, asked per refresh so a library catches up (`checkVideos`).
    public static let embedBackfillCap = 5
    public static let embedCheckConcurrency = 4
    /// How long a refresh waits for the answers, over all its sources. Those it didn't get are asked for next time.
    public static let embedCheckBudget: TimeInterval = 6
    /// How many checks may come back unreadable, with none answering, before a refresh stops asking.
    static let embedCheckGiveUpAfter = 8

    let database: AppDatabase
    let parser: any FeedParser
    let scraper: any PageScraper
    let fetch: RefreshFeedFetch
    let fallbacks: [String: [String]]
    let feedTimeout: TimeInterval
    let concurrency: Int
    let topicSearch: any TopicSearching
    let embedCheck: any YouTubeEmbedChecking
    let embedCheckBudget: TimeInterval

    /// `topicSearch` finds a topic's matches outside the subscriptions and `embedCheck` asks whether a video plays in other
    /// apps; tests pass fakes.
    public init(database: AppDatabase, parser: any FeedParser, scraper: any PageScraper,
                topicSearch: any TopicSearching = DefaultTopicSearch(),
                embedCheck: any YouTubeEmbedChecking = DefaultYouTubeEmbedCheck()) {
        self.init(database: database, parser: parser, scraper: scraper, fetch: Self.liveFetch, topicSearch: topicSearch, embedCheck: embedCheck)
    }

    /// Tests: inject the feed transport, fallbacks, timeout and concurrency.
    init(
        database: AppDatabase, parser: any FeedParser, scraper: any PageScraper, fetch: @escaping RefreshFeedFetch,
        fallbacks: [String: [String]] = Seed.feedFallbacks, feedTimeout: TimeInterval = Self.feedTimeout,
        concurrency: Int = Self.sourceConcurrency, topicSearch: any TopicSearching = DefaultTopicSearch(),
        embedCheck: any YouTubeEmbedChecking = DefaultYouTubeEmbedCheck(), embedCheckBudget: TimeInterval = Self.embedCheckBudget
    ) {
        self.database = database
        self.parser = parser
        self.scraper = scraper
        self.fetch = fetch
        self.fallbacks = fallbacks
        self.feedTimeout = feedTimeout
        self.concurrency = max(1, concurrency)
        self.topicSearch = topicSearch
        self.embedCheck = embedCheck
        self.embedCheckBudget = embedCheckBudget
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
        let fetched = Set(results.compactMap { $0?.ok == true ? $0?.sourceId : nil })
        await checkVideos(sourceIds: all.filter { $0.kind == .youtube && fetched.contains($0.id) }.map(\.id), storedSince: now)
        let result = RefreshResult(ran: true, lastRefreshAt: now, results: results.compactMap { $0 }, pruned: pruned)
        progress(.finished(result))
        return result
    }

    @discardableResult
    public func refreshSource(id: Int64) async throws -> Int {
        guard let src = try await database.source(id: id) else { throw QueryError.notFound("Source") }
        let started = Date()
        let added = try await refresh(src)
        if src.kind == .youtube { await checkVideos(sourceIds: [src.id], storedSince: started) }
        return added
    }

    // MARK: One source

    /// refreshSource(src): fetch, dedupe, upsert, record the attempt, then backfill thumbnails. Returns items
    /// added. On failure records last_error and rethrows.
    func refresh(_ src: Source) async throws -> Int {
        if src.kind == .topic { return try await refreshTopic(src) }
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

    /// A topic's refresh: search the places it follows, then store the matches like a source's items. Matches repeating a
    /// stored item's link under another guid (a news article that was a Hacker News story) are dropped, the cut-off keeps pruned
    /// items from coming back, and article items without a picture get their page's. In the same transaction the topic's
    /// stored items that its rules no longer allow are removed (a place turned off, a title without the keyword, another
    /// language; saved and highlighted ones stay), the points and comments of its stored Hacker News stories are renewed, and
    /// the news articles are grouped into stories (`Queries.groupTopicStories`), so a notification sees one post per story.
    /// Errors are recorded only when every place failed; a place that worked makes the refresh a success.
    func refreshTopic(_ src: Source) async throws -> Int {
        do {
            guard let options = src.topicOptions else { throw QueryError.invalid("Topic has no options") }
            let now = Date()
            let (stored, subscribed, hackerNewsIDs) = try await database.reader.read { db in
                (try Queries.storedItemKeys(db, sourceId: src.id), try Queries.subscriptions(db),
                 try Queries.storedHackerNewsIDs(db, sourceId: src.id, since: Retention.cutoff(now: now)))
            }
            let outcome = await topicSearch.search(options, subscriptions: TopicSubscriptions(sources: subscribed), now: now)
            if outcome.allFailed { throw TopicSearchError(outcome.errorMessage ?? "Nothing could be searched") }
            // The numbers of stories stored earlier move after they were found; one request renews them all. A failure keeps the old ones.
            let stats = options.places.hackerNews && !hackerNewsIDs.isEmpty ? await topicSearch.hackerNewsStats(ids: hackerNewsIDs) : [:]
            let cutoff = Retention.cutoff()
            let fresh = outcome.items.filter { $0.publishedAt >= cutoff }
            let unique = Self.dedupeTopicItems(Array(fresh.prefix(Self.maxTopicItemsPerFetch)), stored: stored)
            let languages = topicSearch.languages
            let rows = try await database.writer.write { db in
                try Queries.removeStaleTopicItems(db, topic: src, languages: languages)
                try Queries.applyHackerNewsStats(db, sourceId: src.id, stats: stats)
                let rows = try Queries.upsertItems(db, sourceId: src.id, items: unique)
                try Queries.groupTopicStories(db, topic: src)
                try Queries.markSourceFetched(db, sourceId: src.id, at: Date(), error: nil)
                return rows
            }
            _ = try? await backfillThumbnails(sourceId: src.id, fresh: Self.newThumbTargets(rows))
            return rows.filter(\.inserted).count
        } catch {
            let message = HTTP.message(error)
            try? await database.writer.write { db in
                try Queries.markSourceFetched(db, sourceId: src.id, at: Date(), error: message)
            }
            throw error
        }
    }

    /// A repeated link is one item, except that a Hacker News story may share its link with an article: the story is the
    /// discussion of the article's story (`Queries.groupTopicStories`), so the two are deduped apart, each among its own kind.
    static func dedupeTopicItems(_ items: [ParsedItem], stored: [StoredItemKey]) -> [ParsedItem] {
        func isThread(_ guid: String) -> Bool { guid.hasPrefix("hn:") }
        let threads = FeedDedupe.dedupe(items.filter { isThread($0.guid) }, stored: stored.filter { isThread($0.guid) }, linkOnly: true)
        let others = FeedDedupe.dedupe(items.filter { !isThread($0.guid) }, stored: stored.filter { !isThread($0.guid) }, linkOnly: true)
        let kept = Dictionary((threads + others).map { ($0.guid, $0) }, uniquingKeysWith: { _, last in last })
        var emitted = Set<String>()
        return items.compactMap { emitted.insert($0.guid).inserted ? kept[$0.guid] : nil }
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
        // YouTube's channel feeds fail at times for channels that exist.
        let attempts = src.kind == .youtube ? FeedDetection.youtubeFeedAttempts : 1
        for url in candidates {
            for attempt in 0..<attempts {
                if attempt > 0 { try await Task.sleep(for: FeedDetection.youtubeFeedRetryDelay) }
                do {
                    let data = try await Self.withDeadline(feedTimeout) { [fetch, feedTimeout] in try await fetch(url, feedTimeout) }
                    return try parser.parse(data, kind: src.kind, feedURL: url)
                } catch {
                    if error is CancellationError { throw error }
                    lastError = error
                }
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

    // MARK: Videos that won't play here

    /// Asks YouTube whether these sources' videos play in other apps and stores the answers: every video stored since
    /// `storedSince`, and up to `embedBackfillCap` of each source's newest not yet known. Comes after the feeds, so it
    /// holds none of their slots, and costs at most `embedCheckBudget` however many channels there are. A video with no
    /// answer stays unknown and is asked about again, and nothing here fails the refresh.
    func checkVideos(sourceIds: [Int64], storedSince: Date) async {
        guard !sourceIds.isEmpty, let targets = try? await database.reader.read({ db in
            try Queries.embedCheckTargets(db, sourceIds: sourceIds, storedSince: storedSince, backfill: Self.embedBackfillCap)
        }), !targets.isEmpty else { return }
        let answers = await Self.askPlayable(targets, check: embedCheck, concurrency: Self.embedCheckConcurrency, budget: embedCheckBudget)
        guard !answers.isEmpty else { return }
        try? await database.writer.write { db in try Queries.storeEmbedChecks(db, playable: answers) }
    }

    /// The answers that came within `budget`, by item id; the checks still running then are cancelled.
    static func askPlayable(_ targets: [EmbedCheckTarget], check: any YouTubeEmbedChecking, concurrency: Int, budget: TimeInterval) async -> [Int64: Bool] {
        // A nil result is the budget running out.
        await withTaskGroup(of: (id: Int64, playable: Bool?)?.self) { group in
            var answers: [Int64: Bool] = [:]
            var next = 0, running = 0, unknown = 0
            func startNext() {
                guard next < targets.count else { return }
                let target = targets[next]
                next += 1
                running += 1
                group.addTask { (target.id, await check.isPlayable(videoID: target.videoId)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                return nil
            }
            for _ in 0..<min(concurrency, targets.count) { startNext() }
            while running > 0, let done = await group.next() {
                guard let done else { break }
                running -= 1
                if let playable = done.playable { answers[done.id] = playable } else { unknown += 1 }
                // Every answer unreadable means YouTube's page changed, which more pages won't fix.
                if answers.isEmpty, unknown >= Self.embedCheckGiveUpAfter { break }
                startNext()
            }
            group.cancelAll()
            return answers
        }
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
