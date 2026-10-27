import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

// MARK: Fixtures

private enum RefreshFixture {
    static func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    struct Entry {
        var guid: String
        var link: String
        var title: String
        var age: TimeInterval = 3600
        var image: String? = nil
        var audio: String? = nil
    }

    static func rss(_ entries: [Entry], channelImage: String? = nil, now: Date = Date()) -> Data {
        let items = entries.map { e in
            var s = "<item><title>\(e.title)</title><link>\(e.link)</link><guid>\(e.guid)</guid><pubDate>\(rfc822(now.addingTimeInterval(-e.age)))</pubDate>"
            if let i = e.image { s += "<media:content url=\"\(i)\" medium=\"image\"/>" }
            if let a = e.audio { s += "<enclosure url=\"\(a)\" type=\"audio/mpeg\" length=\"1\"/>" }
            return s + "</item>"
        }.joined()
        let art = channelImage.map { "<itunes:image href=\"\($0)\"/>" } ?? ""
        return Data("""
            <?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">\
            <channel><title>Blog</title><link>https://blog.example.com/</link>\(art)\(items)</channel></rss>
            """.utf8)
    }
}

/// Thread-safe call recorder for fakes.
private final class RefreshCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var inFlight = 0
    private(set) var peak = 0
    func add(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
    func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

private struct RefreshFakeScraper: PageScraper {
    var scrapeResult: ScrapeResult? = nil
    var images: [String: PageImageResult] = [:]
    var calls: RefreshCalls = RefreshCalls()

    func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult {
        calls.add("scrape \(listingURL) known=\(known.sorted().joined(separator: ","))")
        guard let r = scrapeResult else { throw HTTPError.status(404) }
        return r
    }
    func findArticleLinks(html: String, pageURL: String) -> [String] { [] }
    func listingTitle(html: String, pageURL: String) -> String { "" }
    func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult {
        calls.add("image \(url)")
        return images[url] ?? PageImageResult(image: nil, final: true)
    }
    func fetchLinkItem(url: String, videoID: String?, timeout: TimeInterval) async -> ParsedItem? { nil }
}

private func makeService(
    _ db: AppDatabase, scraper: RefreshFakeScraper = RefreshFakeScraper(), fallbacks: [String: [String]] = [:],
    timeout: TimeInterval = 15, concurrency: Int = 12, feeds: @escaping @Sendable (String) async throws -> Data
) -> DefaultRefreshService {
    DefaultRefreshService(
        database: db, parser: DefaultFeedParser(), scraper: scraper, fetch: { url, _ in try await feeds(url) },
        fallbacks: fallbacks, feedTimeout: timeout, concurrency: concurrency)
}

private func itemRows(_ db: AppDatabase, sourceId: Int64) throws -> [Item] {
    try db.reader.read { try Item.filter(Item.Columns.sourceId == sourceId).order(Item.Columns.guid).fetchAll($0) }
}

private let hnDupFeed = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>
    \(hnItem(50224422, "Missileer", "https://missileer.watch", 111, "Sat, 24 Oct 2026 19:43:27 +0000"))
    \(hnItem(50224300, "The Goose Programming Language", "https://aardappel.github.io/goose/", 170, "Sat, 24 Oct 2026 19:27:41 +0000"))
    \(hnItem(50224100, "The Goose Programming Language", "https://aardappel.github.io/goose/", 231, "Sat, 24 Oct 2026 19:06:55 +0000"))
    \(hnItem(50223000, "Ask HN: What are you working on?", "https://news.ycombinator.com/item?id=50223000", 150, "Sat, 24 Oct 2026 18:00:00 +0000"))
    \(hnItem(50222000, "Ask HN: Best laptop?", "https://news.ycombinator.com/item?id=50222000", 120, "Sat, 24 Oct 2026 17:00:00 +0000"))
    </channel></rss>
    """

private func hnItem(_ id: Int, _ title: String, _ link: String, _ points: Int, _ date: String) -> String {
    """
    <item><title><![CDATA[\(title)]]></title><description><![CDATA[
    <p>Comments URL: <a href="https://news.ycombinator.com/item?id=\(id)">https://news.ycombinator.com/item?id=\(id)</a></p>
    <p>Points: \(points)</p>
    <p># Comments: 1</p>
    ]]></description><pubDate>\(date)</pubDate><link>\(link)</link><dc:creator>x</dc:creator><comments>https://news.ycombinator.com/item?id=\(id)</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=\(id)</guid></item>
    """
}

// MARK: Dedupe (port of scripts/parse-check.ts checkHnDedupe / checkGenericDedupe)

@Suite("FeedDedupe")
struct FeedDedupeTests {
    private func it(_ guid: String, _ url: String, _ title: String, points: Int? = nil) -> ParsedItem {
        ParsedItem(guid: guid, url: url, title: title, publishedAt: Fixture.base, hnPoints: points)
    }
    private func ids(_ xs: [ParsedItem]) -> [Int] { xs.compactMap { Int($0.guid.split(separator: "=").last ?? "") } }
    private func stored(_ id: Int, _ url: String, _ title: String = "The Goose Programming Language") -> StoredItemKey {
        StoredItemKey(guid: "https://news.ycombinator.com/item?id=\(id)", url: url, title: title)
    }

    @Test func hackerNewsSubmissions() throws {
        let feed = try DefaultFeedParser().parse(Data(hnDupFeed.utf8), kind: .rss, feedURL: "https://hnrss.org/newest?points=100")
        let site = "https://news.ycombinator.com/"
        // Both new in one batch: one row, the more popular submission.
        #expect(ids(FeedDedupe.dedupe(feed.items, linkOnly: true, siteURL: site)) == [50224422, 50224100, 50223000, 50222000])
        // First submission already stored: it keeps updating, the second is skipped.
        #expect(ids(FeedDedupe.dedupe(feed.items, stored: [stored(50224300, "https://aardappel.github.io/goose/")], linkOnly: true, siteURL: site))
                == [50224422, 50224300, 50223000, 50222000])
        // Stored link differs only by scheme, www, trailing slash, tracking params or anchor.
        for url in ["http://www.aardappel.github.io/goose", "https://aardappel.github.io/goose/?utm_source=hn#intro", "https://AARDAPPEL.github.io/goose//"] {
            #expect(ids(FeedDedupe.dedupe(feed.items, stored: [stored(1, url, "Goose: a language")], linkOnly: true, siteURL: site))
                    == [50224422, 50223000, 50222000], "\(url)")
        }
        // Both submissions already stored as separate rows: both keep updating.
        let both = [stored(50224300, "https://aardappel.github.io/goose/"), stored(50224100, "https://aardappel.github.io/goose/")]
        #expect(FeedDedupe.dedupe(feed.items, stored: both, linkOnly: true, siteURL: site).count == 5)
        // A third submission of a stored story is still dropped on an aggregator.
        var third = feed.items[1]
        third.guid = "https://news.ycombinator.com/item?id=50229999"
        third.hnPoints = 400
        #expect(ids(FeedDedupe.dedupe(feed.items + [third], stored: both, linkOnly: true, siteURL: site))
                == [50224422, 50224300, 50224100, 50223000, 50222000])
        // Repeated guid in one batch collapses to one.
        #expect(FeedDedupe.dedupe(feed.items + [feed.items[0]], linkOnly: true, siteURL: site).count == 4)
    }

    @Test func genericFeeds() {
        let site = "https://pod.example.com/"
        let pod = [it("e3", "https://pod.example.com/show", "Ep 3"), it("e2", "https://pod.example.com/show", "Ep 2"), it("e1", "https://pod.example.com/show", "Ep 1")]
        #expect(FeedDedupe.dedupe(pod, siteURL: site).count == 3)
        let same = pod.map { var x = $0; x.title = "Weekly show"; return x }
        #expect(FeedDedupe.dedupe(same, siteURL: site).count == 3)
        let sameStored = same.map { StoredItemKey(guid: $0.guid, url: $0.url, title: $0.title) }
        #expect(FeedDedupe.dedupe([it("e4", "https://pod.example.com/show", "Weekly show")], stored: sameStored, siteURL: site).count == 1)
        // Items linking to the site root are never deduped.
        #expect(FeedDedupe.dedupe([it("a", site, "Update"), it("b", "https://www.pod.example.com", "Update")], siteURL: site).count == 2)
        // Same link, different titles: both kept.
        #expect(FeedDedupe.dedupe([it("a", "https://b.example.com/live", "Update 1"), it("b", "https://b.example.com/live", "Update 2")]).count == 2)
        #expect(FeedDedupe.dedupe([it("a", "https://b.example.com/log#v2", "v2"), it("b", "https://b.example.com/log#v1", "v1")]).count == 2)
        // Same link and title under a new guid (a republish): dropped, against stored rows too.
        let out = FeedDedupe.dedupe(
            [it("new", "https://b.example.com/post?utm_medium=rss", "Hello,  World!"), it("x", "https://b.example.com/other", "Other")],
            stored: [StoredItemKey(guid: "old", url: "https://b.example.com/post/", title: "Hello World")])
        #expect(out.map(\.guid) == ["x"])
    }

    @Test func linkKeys() {
        #expect(FeedDedupe.linkKey("https://www.youtube.com/watch?v=a") != FeedDedupe.linkKey("https://www.youtube.com/watch?v=b"))
        #expect(FeedDedupe.linkKey("https://b.example.com/p?b=2&a=1&utm_source=x") == FeedDedupe.linkKey("http://b.example.com/p/?a=1&b=2"))
        #expect(FeedDedupe.linkKey("https://app.example.com/#/a") != FeedDedupe.linkKey("https://app.example.com/#/b"))
        #expect(FeedDedupe.linkKey("https://b.example.com/") == nil)
        #expect(FeedDedupe.linkKey("mailto:a@b.c") == nil)
        #expect(FeedDedupe.linkKey("https://b.example.com:443/x") == "b.example.com/x")
        #expect(FeedDedupe.linkKey("http://b.example.com:8080/x") == "b.example.com:8080/x")
        #expect(FeedDedupe.linkKey("https://b.example.com/s?q=a+b&fbclid=1") == "b.example.com/s?q=a+b")
        #expect(FeedDedupe.linkKey("https://b.example.com/s?q=a%20b") == "b.example.com/s?q=a+b")
        #expect(FeedDedupe.linkKey("https://b.example.com/x#!/r") == "b.example.com/x#!/r")
        #expect(FeedDedupe.titleKey("  Hello,  World! ") == "hello world")
        #expect(FeedDedupe.titleKey("Café — Ünïcode 2") == "café ünïcode 2")
    }

    @Test func newThumbTargets() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var rows: [UpsertedItem] = []
        for i in 0..<30 {
            let thumb: String? = i % 10 == 0 ? "https://blog.example.com/feed-thumb.png" : nil
            let published = base.addingTimeInterval(Double(i) * 86400)
            rows.append(UpsertedItem(id: Int64(i + 1), url: "https://blog.example.com/p/\(i + 1)", thumbnailUrl: thumb,
                                     publishedAt: published, inserted: i < 25))
        }
        let targets = DefaultRefreshService.newThumbTargets(rows)
        #expect(targets.count == 12)
        let onlyInsertedWithoutThumb = targets.allSatisfy { (t: ThumbnailTarget) -> Bool in t.id <= 25 && (t.id - 1) % 10 != 0 }
        #expect(onlyInsertedWithoutThumb)
        let firstIDs: [Int64] = targets.prefix(3).map { $0.id }
        #expect(firstIDs == [25, 24, 23])
    }
}

// MARK: Refresh service

@Suite("DefaultRefreshService")
struct RefreshServiceTests {
    @Test func rssSourceInsertsUpdatesAndRecordsFetch() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, feedUrl: "https://blog.example.com/feed")
        let entries: [RefreshFixture.Entry] = [
            .init(guid: "a", link: "https://blog.example.com/a", title: "A", image: "https://cdn.example.com/a.jpg"),
            .init(guid: "b", link: "https://blog.example.com/b", title: "B", age: 7200),
            // Past the 14-day retention window: skipped so pruned rows don't come back.
            .init(guid: "old", link: "https://blog.example.com/old", title: "Old", age: 20 * 86400),
        ]
        let svc = makeService(db) { url in
            #expect(url == "https://blog.example.com/feed")
            return RefreshFixture.rss(entries)
        }
        #expect(try await svc.refreshSource(id: src.id) == 2)
        let rows = try itemRows(db, sourceId: src.id)
        #expect(rows.map(\.guid) == ["a", "b"])
        #expect(rows[0].thumbnailUrl == "https://cdn.example.com/a.jpg")
        let after = try #require(try await db.source(id: src.id))
        #expect(after.lastFetchedAt != nil)
        #expect(after.lastError == nil)
        // A second fetch updates in place.
        #expect(try await svc.refreshSource(id: src.id) == 0)
        #expect(try itemRows(db, sourceId: src.id).count == 2)
    }

    @Test func fetchErrorIsRecordedAndRethrown() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let svc = makeService(db) { _ in throw HTTPError.status(503) }
        await #expect(throws: HTTPError.status(503)) { try await svc.refreshSource(id: src.id) }
        let after = try #require(try await db.source(id: src.id))
        #expect(after.lastError == "HTTP 503")
        #expect(after.lastFetchedAt != nil)
        await #expect(throws: QueryError.notFound("Source")) { try await svc.refreshSource(id: 999) }
    }

    @Test func parseErrorIsRecorded() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let svc = makeService(db) { _ in Data("<html><body>not a feed</body></html>".utf8) }
        await #expect(throws: (any Error).self) { try await svc.refreshSource(id: src.id) }
        #expect(try await db.source(id: src.id)?.lastError?.isEmpty == false)
    }

    @Test func fallbackURLsAreTriedInOrder() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, feedUrl: "https://blog.example.com/broken")
        let calls = RefreshCalls()
        let svc = makeService(db, fallbacks: ["https://blog.example.com/broken": ["https://blog.example.com/alt1", "https://blog.example.com/alt2"]]) { url in
            calls.add(url)
            if url.hasSuffix("alt2") { return RefreshFixture.rss([.init(guid: "x", link: "https://blog.example.com/x", title: "X")]) }
            throw HTTPError.status(404)
        }
        #expect(try await svc.refreshSource(id: src.id) == 1)
        #expect(calls.all == ["https://blog.example.com/broken", "https://blog.example.com/alt1", "https://blog.example.com/alt2"])
    }

    @Test func feedTimeoutIsEnforced() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let svc = makeService(db, timeout: 0.05) { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return Data()
        }
        let start = Date()
        await #expect(throws: HTTPError.timedOut) { try await svc.refreshSource(id: src.id) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try await db.source(id: src.id)?.lastError == "Timed out")
    }

    @Test func firstFetchPromotesPodcast() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Show", url: "https://pod.example.com", feedUrl: "https://pod.example.com/rss", kind: .rss, group: "blogs")
        let feed = RefreshFixture.rss(
            [.init(guid: "e1", link: "https://pod.example.com/e1", title: "Ep 1", image: "https://pod.example.com/e1.jpg", audio: "https://cdn.example.com/e1.mp3"),
             .init(guid: "e2", link: "https://pod.example.com/e2", title: "Ep 2", age: 7200, image: "https://pod.example.com/e2.jpg", audio: "https://cdn.example.com/e2.mp3")],
            channelImage: "https://pod.example.com/art.jpg")
        let svc = makeService(db) { _ in feed }
        #expect(try await svc.refreshSource(id: src.id) == 2)
        let after = try #require(try await db.source(id: src.id))
        #expect(after.kind == .podcast)
        #expect(after.group == "podcast")
        #expect(after.iconUrl == "https://pod.example.com/art.jpg")
        #expect(try itemRows(db, sourceId: src.id).first?.audioUrl == "https://cdn.example.com/e1.mp3")

        // Not on later fetches: a source the user changed back stays put.
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE sources SET kind = 'rss', \"group\" = 'blogs' WHERE id = ?", arguments: [src.id])
        }
        try await svc.refreshSource(id: src.id)
        #expect(try await db.source(id: src.id)?.kind == .rss)
    }

    @Test func pageSourceUsesScraperAndSeenURLs() async throws {
        let db = try Fixture.db()
        var src = try Fixture.source(db, title: "News", url: "https://news.example.com", feedUrl: "https://news.example.com/news", kind: .page, group: "labs")
        let seen = (0..<305).map { "https://news.example.com/old/\($0)" }
        src.seenUrls = seen
        try await db.writer.write { [src] d in try src.update(d) }
        let stored = try Fixture.items(db, sourceId: src.id, [ParsedItem(guid: "https://news.example.com/s", url: "https://news.example.com/s", title: "S", publishedAt: Date())])
        #expect(stored.count == 1)

        let scraped = ParsedItem(guid: "https://news.example.com/new", url: "https://news.example.com/new", title: "New", publishedAt: Date(), thumbnailUrl: "https://news.example.com/og.png")
        let scraper = RefreshFakeScraper(scrapeResult: ScrapeResult(
            listingUrl: "https://news.example.com/news", links: [scraped.url],
            items: [scraped], processed: [scraped.url, "https://news.example.com/landing", seen[0]]))
        let svc = makeService(db, scraper: scraper) { _ in Issue.record("feeds are not fetched for page sources"); return Data() }
        #expect(try await svc.refreshSource(id: src.id) == 1)

        let call = try #require(scraper.calls.all.first)
        #expect(call.hasPrefix("scrape https://news.example.com/news known="))
        #expect(call.hasSuffix(",https://news.example.com/s"))   // stored item urls are known
        #expect(call.contains("https://news.example.com/old/304")) // so are seen urls
        let after = try #require(try await db.source(id: src.id))
        let newSeen = try #require(after.seenUrls)
        #expect(newSeen.count == 300)
        #expect(Array(newSeen.prefix(3)) == [scraped.url, "https://news.example.com/landing", seen[0]])
        #expect(newSeen[3] == seen[1])
        // Page sources get og:image while scraping; no backfill.
        #expect(!scraper.calls.all.contains { $0.hasPrefix("image ") })
    }

    @Test func thumbnailBackfill() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, feedUrl: "https://blog.example.com/feed")
        // An older item without a thumbnail that was never tried.
        let old = try Fixture.items(db, sourceId: src.id, [ParsedItem(guid: "old", url: "https://blog.example.com/old", title: "Old", publishedAt: Date().addingTimeInterval(-86400))])[0]
        let entries: [RefreshFixture.Entry] = [
            .init(guid: "found", link: "https://blog.example.com/found", title: "Found"),
            .init(guid: "miss", link: "https://blog.example.com/miss", title: "Miss", age: 7200),
            .init(guid: "temp", link: "https://blog.example.com/temp", title: "Temp", age: 9000),
            .init(guid: "has", link: "https://blog.example.com/has", title: "Has", image: "https://cdn.example.com/has.jpg"),
        ]
        let scraper = RefreshFakeScraper(images: [
            "https://blog.example.com/found": PageImageResult(image: "https://blog.example.com/og.png", final: true),
            "https://blog.example.com/temp": PageImageResult(image: nil, final: false),
            "https://blog.example.com/old": PageImageResult(image: "https://blog.example.com/old.png", final: true),
        ])
        let svc = makeService(db, scraper: scraper) { _ in RefreshFixture.rss(entries) }
        #expect(try await svc.refreshSource(id: src.id) == 4)

        let byGuid = Dictionary(uniqueKeysWithValues: try itemRows(db, sourceId: src.id).map { ($0.guid, $0) })
        #expect(byGuid["found"]?.thumbnailUrl == "https://blog.example.com/og.png")
        #expect(byGuid["found"]?.thumbnailChecked == true)
        #expect(byGuid["miss"]?.thumbnailUrl == nil)
        #expect(byGuid["miss"]?.thumbnailChecked == true)
        #expect(byGuid["temp"]?.thumbnailChecked == false)   // temporary miss: retried next refresh
        #expect(byGuid["has"]?.thumbnailChecked == false)    // feed thumbnail: never fetched
        #expect(byGuid["old"]?.thumbnailUrl == "https://blog.example.com/old.png")
        #expect(old.id == byGuid["old"]?.id)
        let images = scraper.calls.all.filter { $0.hasPrefix("image ") }
        #expect(images.count == 4)
        #expect(!images.contains("image https://blog.example.com/has"))
    }

    @Test func youtubeSourcesSkipBackfill() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "YT", url: "https://www.youtube.com/channel/UC1", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1", kind: .youtube, group: "youtube")
        let scraper = RefreshFakeScraper()
        let svc = makeService(db, scraper: scraper) { _ in RefreshFixture.rss([.init(guid: "v", link: "https://www.youtube.com/watch?v=abc", title: "V")]) }
        #expect(try await svc.refreshSource(id: src.id) == 1)
        #expect(scraper.calls.all.isEmpty)
    }

    @Test func aggregatorDedupesThroughRefresh() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Hacker News", url: "https://news.ycombinator.com", feedUrl: "https://hnrss.org/newest?points=100", group: "aggregator")
        // Pin the dates inside the retention window.
        let feed = hnDupFeed.replacingOccurrences(of: "Oct 2026", with: RefreshFixture.rfc822(Date()).dropFirst(8).prefix(8).description)
        let svc = makeService(db, scraper: RefreshFakeScraper()) { _ in Data(feed.utf8) }
        try await svc.refreshSource(id: src.id)
        let guids = try itemRows(db, sourceId: src.id).map(\.guid)
        #expect(guids.count == 4)
        #expect(!guids.contains("https://news.ycombinator.com/item?id=50224300"))
    }

    @Test func refreshAllRunsConcurrentlyReportsAndPrunes() async throws {
        let db = try Fixture.db()
        var ids: [Int64] = []
        for i in 0..<6 {
            ids.append(try Fixture.source(db, title: "S\(i)", url: "https://s\(i).example.com", feedUrl: "https://s\(i).example.com/feed").id)
        }
        // An unsaved item older than retention gets pruned; a saved one stays.
        let keep = try Fixture.items(db, sourceId: ids[0], [
            ParsedItem(guid: "ancient", url: "https://s0.example.com/ancient", title: "Ancient", publishedAt: Date().addingTimeInterval(-30 * 86400)),
            ParsedItem(guid: "saved", url: "https://s0.example.com/saved", title: "Saved", publishedAt: Date().addingTimeInterval(-30 * 86400)),
        ])
        try await db.setSaved(itemId: keep[1].id, saved: true)

        let calls = RefreshCalls()
        let svc = makeService(db, concurrency: 3) { url in
            calls.enter()
            defer { calls.leave() }
            try await Task.sleep(nanoseconds: 20_000_000)
            if url.contains("s3.") { throw HTTPError.status(500) }
            let host = URL(string: url)?.host ?? ""
            return RefreshFixture.rss([.init(guid: host, link: "https://\(host)/post", title: host)])
        }
        let events = RefreshCalls()
        let r = try await svc.refreshAll(force: false) { e in
            switch e {
            case .started(_, let total): events.add("started \(total)")
            case .sourceFinished(let s, let done, let total): events.add("source \(s.title) \(s.ok) \(done)/\(total)")
            case .finished(let r): events.add("finished \(r.ran)")
            }
        }
        #expect(r.ran)
        #expect(r.pruned == 1)
        #expect(r.results.map(\.sourceId) == ids)               // in source order, not completion order
        #expect(r.results.filter(\.ok).count == 5)
        let failed = try #require(r.results.first { !$0.ok })
        #expect(failed.title == "S3")
        #expect(failed.error == "HTTP 500")
        #expect(r.results.filter(\.ok).allSatisfy { $0.added == 1 })
        #expect(calls.peak == 3)
        #expect(try await db.lastRefreshAt() != nil)
        let ev = events.all
        #expect(ev.first == "started 6")
        #expect(ev.last == "finished true")
        #expect(ev.count == 8)
        #expect(ev.contains("source S3 false") == false)
        #expect(ev.contains { $0.hasPrefix("source S3 false ") })
        #expect(ev[6].hasSuffix("6/6"))

        // Within 15 minutes: skipped unless forced.
        let skipped = try await svc.refreshAll(force: false)
        #expect(!skipped.ran)
        #expect(skipped.lastRefreshAt != nil)
        #expect(try await svc.refreshAll(force: true).ran)
    }

    @Test func concurrentCallsClaimOnce() async throws {
        let db = try Fixture.db()
        try Fixture.source(db)
        let svc = makeService(db) { _ in RefreshFixture.rss([]) }
        async let a = svc.refreshAll(force: false)
        async let b = svc.refreshAll(force: false)
        let (ra, rb) = try await (a, b)
        #expect([ra.ran, rb.ran].filter { $0 }.count == 1)
    }

    @Test func progressStreamAndExistentialDispatch() async throws {
        let db = try Fixture.db()
        try Fixture.source(db)
        let svc: any RefreshService = makeService(db) { _ in RefreshFixture.rss([.init(guid: "a", link: "https://blog.example.com/a", title: "A")]) }
        var kinds: [String] = []
        for try await e in svc.refreshUpdates(force: true) {
            switch e {
            case .started: kinds.append("started")
            case .sourceFinished(let s, _, _): kinds.append("source \(s.added)")
            case .finished(let r): kinds.append("finished \(r.ran)")
            }
        }
        #expect(kinds == ["started", "source 1", "finished true"])
        var skippedEvents: [String] = []
        for try await e in svc.refreshUpdates(force: false) {
            if case .finished(let r) = e { skippedEvents.append("finished \(r.ran)") } else { skippedEvents.append("other") }
        }
        #expect(skippedEvents == ["finished false"])
    }
}
