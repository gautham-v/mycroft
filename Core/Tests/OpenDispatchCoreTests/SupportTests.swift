import Foundation
import Testing
@testable import OpenDispatchCore

@Suite("Support")
struct SupportTests {
    @Test func relativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func r(_ secondsAgo: Double) -> String { RelativeTime.format(now.addingTimeInterval(-secondsAgo), now: now) }
        #expect(r(30) == "now")
        #expect(r(-500) == "now")
        #expect(r(23 * 60) == "23m")
        #expect(r(3 * 3600) == "3h")
        #expect(r(2 * 86400) == "2d")
        #expect(r(35 * 86400) == "5w")
        #expect(r(800 * 86400) == "2y")
        #expect(RelativeTime.isStale(nil, now: now))
        #expect(!RelativeTime.isStale(now.addingTimeInterval(-60), now: now))
        #expect(RelativeTime.isStale(now.addingTimeInterval(-16 * 60), now: now))
    }

    @Test func verticalVideo() {
        func item(_ url: String, videoID: String? = "abc") -> Item {
            Item(sourceId: 1, guid: url, url: url, title: "t", publishedAt: Date(), videoId: videoID)
        }
        #expect(item("https://www.youtube.com/shorts/abc").isVerticalVideo)
        #expect(!item("https://www.youtube.com/watch?v=abc").isVerticalVideo)
        #expect(!item("https://example.com/shorts/abc", videoID: nil).isVerticalVideo)
    }

    @Test func normalizeSourceURL() throws {
        #expect(try SourceURL.normalize("example.com") == "https://example.com/")
        #expect(try SourceURL.normalize("  https://Example.com/a?b=1#c ") == "https://example.com/a?b=1#c")
        #expect(try SourceURL.normalize("//simonwillison.net/atom/") == "https://simonwillison.net/atom/")
        #expect(try SourceURL.normalize("http://localhost:3000") == "http://localhost:3000/")
        #expect(throws: SourceURLError.empty) { try SourceURL.normalize("  ") }
        #expect(throws: SourceURLError.unsupportedScheme) { try SourceURL.normalize("ftp://x.com") }
        #expect(throws: SourceURLError.invalid) { try SourceURL.normalize("notaurl") }
        #expect(throws: SourceURLError.invalid) { try SourceURL.normalize("a..b") }
    }

    @Test func wwwAlternate() {
        #expect(SourceURL.wwwAlternate("https://example.com/x") == "https://www.example.com/x")
        #expect(SourceURL.wwwAlternate("https://www.example.com/x") == "https://example.com/x")
        #expect(SourceURL.wwwAlternate("https://www.com/") == nil)
        #expect(SourceURL.wwwAlternate("http://127.0.0.1/") == nil)
        #expect(SourceURL.wwwAlternate("http://localhost/") == nil)
    }

    @Test func postSources() {
        #expect(PostSource.isPostURL("https://x.com/simonw"))
        #expect(PostSource.isPostURL("HTTPS://WWW.Twitter.com/a"))
        #expect(PostSource.isPostURL("https://mobile.x.com/a"))
        #expect(PostSource.isPostURL("https://bsky.app/profile/x"))
        #expect(PostSource.isPostURL("https://threads.net/@x"))
        #expect(PostSource.isPostURL("https://mastodon.social/@x"))
        #expect(PostSource.isPostURL("https://x.com"))
        #expect(PostSource.isPostURL("https://bsky.app"))
        #expect(PostSource.isPostURL("https://mastodon.social"))
        #expect(!PostSource.isPostURL("https://notx.com"))
        #expect(!PostSource.isPostURL("https://notx.com/a"))
        #expect(!PostSource.isPostURL("https://mastodon.social1/@x"))
        #expect(!PostSource.isPostURL("https://x.com.evil.org/a"))
    }

    @Test func hostsAndText() {
        #expect(URLHost.host(of: "https://www.theverge.com/rss") == "theverge.com")
        #expect(URLHost.host(of: "garbage") == "")
        #expect(URLHost.faviconURL(host: "openai.com")?.absoluteString == "https://www.google.com/s2/favicons?domain=openai.com&sz=64")
        #expect(TextFormat.duration(nil) == nil)
        #expect(TextFormat.duration(65) == "1:05")
        #expect(TextFormat.duration(3725) == "1:02:05")
        #expect(TextFormat.stripHTML("<p>Hi &amp; <b>there</b></p><script>x()</script>") == "Hi & there")
        #expect(TextFormat.isXPost("https://x.com/a/status/123"))
        #expect(!TextFormat.isXPost("https://x.com/a"))
        let h = TextFormat.splitHandle("Kun Chen (@kunchenguid)")
        #expect(h.name == "Kun Chen")
        #expect(h.handle == "kunchenguid")
        #expect(TextFormat.splitHandle("Plain").handle == nil)
        #expect(TextFormat.monogram(title: "The Verge", host: "") == "V")
        #expect(TextFormat.badgeColorIndex("simonwillison.net") == 0)
        #expect(TextFormat.badgeColorIndex("openai.com") == 5)
        #expect(FeedView(parsing: "video") == .video)
        #expect(FeedView(parsing: "bogus") == .all)
    }

    @Test func readabilityIsBundled() {
        #expect(BundledResources.readabilityJS()?.contains("function Readability") == true)
    }
}

@Suite("Services")
struct ServiceTests {
    struct FakeDetector: FeedDetector {
        func detect(_ url: String) async throws -> DetectedFeed {
            DetectedFeed(title: "Found", url: url, feedUrl: url + "feed", kind: .rss, group: "blogs")
        }
    }

    struct FakeExtractor: ContentExtractor {
        func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult {
            ExtractResult(contentHtml: "<p>article \(feed == nil ? "nofeed" : "feed")</p>", leadImage: "https://e.com/lead.jpg")
        }
        func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult {
            ExtractResult(contentHtml: "<p>notes</p>", leadImage: nil)
        }
    }

    func services(_ db: AppDatabase) -> OpenDispatchServices {
        let live = OpenDispatchServices.live(database: db)
        return OpenDispatchServices(database: db, feedParser: live.feedParser, scraper: live.scraper, detector: FakeDetector(),
                                extractor: FakeExtractor(), opml: live.opml, integrations: live.integrations, refresh: live.refresh)
    }

    @Test func addSourceNormalizesAndInserts() async throws {
        let db = try Fixture.db()
        let svc = services(db)
        let (s, existed) = try await svc.addSource(url: "blog.example.com")
        #expect(!existed)
        #expect(s.feedUrl == "https://blog.example.com/feed")
        #expect(try await svc.addSource(url: "https://blog.example.com/").existed)
    }

    @Test func contentServiceCachesAndSkipsYouTube() async throws {
        let db = try Fixture.db()
        let svc = services(db)
        let rss = try Fixture.source(db)
        let yt = try Fixture.source(db, title: "YT", url: "https://www.youtube.com/channel/UC1", kind: .youtube, group: "youtube")
        let a = try Fixture.items(db, sourceId: rss.id, Fixture.parsed(1, prefix: "a"))[0]
        let v = try Fixture.items(db, sourceId: yt.id, Fixture.parsed(1, prefix: "v"))[0]
        let first = try await svc.content.content(forItem: a.id)
        #expect(first.contentHtml == "<p>article feed</p>")
        #expect(first.leadImage == "https://e.com/lead.jpg")
        #expect(try await db.feedItem(id: a.id)?.hasContent == true)
        #expect(try await svc.content.content(forItem: v.id).contentHtml == nil)
        await #expect(throws: QueryError.notFound("Item")) { try await svc.content.content(forItem: 999) }
    }

    @Test func stubRefreshHonorsStaleness() async throws {
        let db = try Fixture.db()
        let svc = OpenDispatchServices.live(database: db)
        let r1 = try await svc.refresh.refreshAll(force: false)
        #expect(r1.ran)
        let r2 = try await svc.refresh.refreshAll(force: false)
        #expect(!r2.ran)
        #expect(try await svc.refresh.refreshAll(force: true).ran)
    }
}
