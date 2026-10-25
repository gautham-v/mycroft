import Foundation
import Testing
@testable import OpenfeedCore

// MARK: - Fakes

/// Records requested URLs and answers them from a handler (no network).
private final class FakeNet: @unchecked Sendable {
    struct Reply { var status: Int = 200; var body: String = ""; var contentType: String = "text/html"; var finalURL: String? }
    enum Failure: Error { case dns }

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _headers: [[String: String]] = []
    let handler: @Sendable (String) throws -> Reply

    init(_ handler: @escaping @Sendable (String) throws -> Reply) { self.handler = handler }

    var calls: [String] { lock.withLock { _calls } }
    var headers: [[String: String]] { lock.withLock { _headers } }

    var fetch: DefaultFeedDetector.Fetch {
        { [self] url, headers in
            lock.withLock { _calls.append(url); _headers.append(headers) }
            let r = try handler(url)
            guard let u = URL(string: r.finalURL ?? url),
                  let res = HTTPURLResponse(url: u, statusCode: r.status, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": r.contentType]) else { throw HTTPError.invalidURL(url) }
            return (Data(r.body.utf8), res)
        }
    }
}

/// Minimal feed parser: <title>, <link>, itunes:image, isPodcast when an itunes namespace is present.
private struct FakeParser: FeedParser {
    func parse(_ data: Data, kind: SourceKind, feedURL: String) throws -> ParsedFeed {
        let xml = String(decoding: data, as: UTF8.self)
        func first(_ re: Regex<(Substring, Substring)>) -> String? { xml.firstMatch(of: re).map { String($0.1) } }
        guard xml.contains("<rss") || xml.contains("<feed") else { throw FeedParserError.invalidFeed("no root") }
        return ParsedFeed(
            title: first(#/<title>([^<]*)<\/title>/#),
            link: first(#/<link>([^<]*)<\/link>/#),
            isPodcast: xml.contains("xmlns:itunes"),
            imageUrl: first(#/<itunes:image href="([^"]*)"/#))
    }

    func itemHTML(in data: Data, guid: String, url: String) -> String? { nil }
}

/// Article links = every href containing "/posts/"; title = <title>.
private struct FakeScraper: PageScraper {
    func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult {
        ScrapeResult(listingUrl: listingURL, links: [], items: [], processed: [])
    }

    func findArticleLinks(html: String, pageURL: String) -> [String] {
        html.matches(of: #/href="([^"]*\/posts\/[^"]*)"/#).map { String($0.1) }
    }

    func listingTitle(html: String, pageURL: String) -> String {
        html.firstMatch(of: #/<title>([^<]*)<\/title>/#).map { String($0.1) } ?? URLHost.host(of: pageURL)
    }

    func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult { PageImageResult(image: nil, final: true) }
}

private func detector(_ net: FakeNet) -> DefaultFeedDetector {
    DefaultFeedDetector(parser: FakeParser(), scraper: FakeScraper(), fetch: net.fetch)
}

// MARK: - Fixtures

private enum DetectFixture {
    static let channel = "UCsBjURrPoezykLs9EqgamOA"
    static let ytFeedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channel)"
    static let ytFeed = """
        <?xml version="1.0" encoding="UTF-8"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
        <title>Fireship</title><entry><yt:videoId>dQw4w9WgXcQ</yt:videoId></entry></feed>
        """
    static let ytChannelPage = """
        <html><head><title>Fireship - YouTube</title></head><body><script>var ytInitialData = {"metadata":{"channelMetadataRenderer":{"title":"Fireship","externalId":"\(channel)"}},"header":{"channelId":"\(channel)"}};</script></body></html>
        """
    static let blogFeed = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Acme Blog</title><link>https://www.acme.com/</link><item><title>Hi</title></item></channel></rss>
        """
    static let podcast = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>The Show</title><link>https://show.example.com/</link><itunes:image href="https://cdn.example.com/show.jpg"/>
        <item><title>Ep 1</title><enclosure url="https://cdn.example.com/ep1.mp3" type="audio/mpeg" length="1"/></item></channel></rss>
        """
    static let blogHome = """
        <!doctype html><html><head><title>Acme</title>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="Acme Blog" href="/feed.xml?a=1&amp;b=2">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://cdn.acme.com/atom.xml'>
        <link rel="alternate" hreflang="fr" href="https://acme.com/fr/">
        </head><body><a href="/posts/one">One</a></body></html>
        """
    static let newsPage = """
        <html><head><title>Lab News</title></head><body><nav><a href="/about">About</a></nav>
        <a href="https://lab.example/news/posts/a">A</a><a href="https://lab.example/news/posts/b">B</a></body></html>
        """
}

// MARK: - Pure helpers

@Suite("Feed detection helpers")
struct FeedDetectionHelperTests {
    @Test func channelIdFromURL() {
        #expect(FeedDetection.youtubeChannelID(fromURL: "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA/videos") == "UCsBjURrPoezykLs9EqgamOA")
        #expect(FeedDetection.youtubeChannelID(fromURL: "https://www.youtube.com/@fireship") == nil)
        #expect(FeedDetection.youtubeChannelID(fromURL: "https://www.youtube.com/channel/UCshort") == nil)
    }

    @Test func youtubeHosts() {
        #expect(FeedDetection.isYouTubeURL("https://www.youtube.com/@fireship"))
        #expect(FeedDetection.isYouTubeURL("https://m.youtube.com/@fireship"))
        #expect(FeedDetection.isYouTubeURL("https://youtube.com/channel/x"))
        #expect(!FeedDetection.isYouTubeURL("https://notyoutube.com/"))
        #expect(!FeedDetection.isYouTubeURL("https://youtu.be/abc"))
    }

    @Test func channelIdInHTML() {
        #expect(FeedDetection.findChannelID(inHTML: #"foo "channelId":"UCsBjURrPoezykLs9EqgamOA" bar"#) == "UCsBjURrPoezykLs9EqgamOA")
        #expect(FeedDetection.findChannelID(inHTML: #""externalId":"UC0123456789abcdefghij_-""#) == "UC0123456789abcdefghij_-")
        #expect(FeedDetection.findChannelID(inHTML: "<link href=\"/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA\">") == "UCsBjURrPoezykLs9EqgamOA")
        #expect(FeedDetection.findChannelID(inHTML: "<html>nothing</html>") == nil)
    }

    @Test func alternateFeeds() {
        #expect(FeedDetection.findAlternateFeeds(html: #"<link rel="alternate" type="application/rss+xml" href="/feed.xml">"#, base: "https://x.com/blog")
            == ["https://x.com/feed.xml"])
        #expect(FeedDetection.findAlternateFeeds(html: DetectFixture.blogHome, base: "https://www.acme.com/")
            == ["https://www.acme.com/feed.xml?a=1&b=2", "https://cdn.acme.com/atom.xml"])
        #expect(FeedDetection.findAlternateFeeds(html: #"<link rel="alternate stylesheet" type="text/css" href="/a.css">"#, base: "https://x.com/").isEmpty)
        #expect(FeedDetection.findAlternateFeeds(html: #"<link rel="alternate" type="application/rss+xml" href="relative.xml">"#, base: "https://x.com/blog/")
            == ["https://x.com/blog/relative.xml"])
    }

    @Test func looksLikeFeed() {
        #expect(FeedDetection.looksLikeFeed(DetectFixture.blogFeed))
        #expect(FeedDetection.looksLikeFeed(DetectFixture.ytFeed))
        #expect(FeedDetection.looksLikeFeed(#"<?xml version="1.0"?><rdf:RDF xmlns:rdf="x">"#))
        #expect(!FeedDetection.looksLikeFeed("<html><head><title>feed</title></head></html>"))
        #expect(!FeedDetection.looksLikeFeed(String(repeating: " ", count: 2001) + "<rss>"))
    }

    @Test func origins() {
        #expect(FeedDetection.siteOrigin("https://www.acme.com/blog/", fallback: "https://x.com/feed") == "https://www.acme.com")
        #expect(FeedDetection.siteOrigin(nil, fallback: "https://x.com:8080/feed") == "https://x.com:8080")
        #expect(FeedDetection.siteOrigin("not a url", fallback: "https://x.com/feed") == "https://x.com/feed")
    }

    @Test func podcastURLs() {
        #expect(FeedDetection.applePodcastID("https://podcasts.apple.com/us/podcast/the-daily/id1200361736") == "1200361736")
        #expect(FeedDetection.applePodcastID("https://podcasts.apple.com/us/podcast/the-show/id1200361736?i=1000") == "1200361736")
        #expect(FeedDetection.applePodcastID("https://itunes.apple.com/podcast?id=42") == "42")
        #expect(FeedDetection.applePodcastID("https://apple.com/id123") == nil)
        #expect(FeedDetection.isSpotifyShowURL("https://open.spotify.com/show/abc123"))
        #expect(FeedDetection.isSpotifyShowURL("https://open.spotify.com/episode/abc123"))
        #expect(!FeedDetection.isSpotifyShowURL("https://open.spotify.com/track/abc123"))
    }

    @Test func pageSourceURL() {
        #expect(FeedDetection.pageSourceURL("https://lab.example/news/") == "https://lab.example/news")
        #expect(FeedDetection.pageSourceURL("https://lab.example/news/?cat=ai#top") == "https://lab.example/news?cat=ai")
        #expect(FeedDetection.pageSourceURL("https://lab.example/") == "https://lab.example/")
    }
}

// MARK: - detect()

@Suite("DefaultFeedDetector")
struct DefaultFeedDetectorTests {
    @Test func plainFeedURL() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.blogFeed, contentType: "application/rss+xml") }
        let d = try await detector(net).detect("https://www.acme.com/feed.xml")
        #expect(d == DetectedFeed(title: "Acme Blog", url: "https://www.acme.com", feedUrl: "https://www.acme.com/feed.xml", kind: .rss, group: "blogs"))
        #expect(net.calls == ["https://www.acme.com/feed.xml"])
    }

    @Test func feedURLAfterRedirect() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.blogFeed, finalURL: "https://feeds.acme.com/main") }
        let d = try await detector(net).detect("https://acme.com/rss")
        #expect(d.feedUrl == "https://feeds.acme.com/main")
    }

    @Test func podcastFeed() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.podcast, contentType: "application/rss+xml") }
        let d = try await detector(net).detect("https://show.example.com/feed.xml")
        #expect(d.kind == .podcast)
        #expect(d.group == "podcast")
        #expect(d.iconUrl == "https://cdn.example.com/show.jpg")
        #expect(d.url == "https://show.example.com")
        #expect(d.title == "The Show")
    }

    @Test func applePodcastsLookup() async throws {
        let net = FakeNet { u in
            u.hasPrefix("https://itunes.apple.com/lookup")
                ? .init(body: #"{"resultCount":1,"results":[{"collectionName":"x"},{"feedUrl":"https://show.example.com/feed.xml"}]}"#, contentType: "application/json")
                : .init(body: DetectFixture.podcast, contentType: "application/rss+xml")
        }
        let d = try await detector(net).detect("https://podcasts.apple.com/us/podcast/the-show/id1200361736?i=1000")
        #expect(net.calls.first == "https://itunes.apple.com/lookup?id=1200361736&entity=podcast")
        #expect(d.feedUrl == "https://show.example.com/feed.xml")
        #expect(d.kind == .podcast)
    }

    @Test func applePodcastsWithoutFeed() async throws {
        let net = FakeNet { _ in .init(body: #"{"results":[]}"#, contentType: "application/json") }
        await #expect(throws: FeedDetectionError("Apple Podcasts has no public RSS feed for this show")) {
            try await detector(net).detect("https://podcasts.apple.com/us/podcast/x/id1")
        }
    }

    @Test func spotifyRejected() async throws {
        let net = FakeNet { _ in .init() }
        do {
            _ = try await detector(net).detect("https://open.spotify.com/show/abc123")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Spotify does not expose RSS"))
        }
        #expect(net.calls.isEmpty)
    }

    @Test func youtubeHandle() async throws {
        let net = FakeNet { u in
            u.contains("/feeds/videos.xml") ? .init(body: DetectFixture.ytFeed, contentType: "application/atom+xml")
                                            : .init(body: DetectFixture.ytChannelPage)
        }
        let d = try await detector(net).detect("https://www.youtube.com/@fireship")
        #expect(d == DetectedFeed(title: "Fireship", url: "https://www.youtube.com/channel/\(DetectFixture.channel)",
                                  feedUrl: DetectFixture.ytFeedURL, kind: .youtube, group: "youtube"))
        #expect(net.calls == ["https://www.youtube.com/@fireship", DetectFixture.ytFeedURL])
        #expect(net.headers.first?["Cookie"] == "CONSENT=YES+1")
        #expect(net.headers.first?["Accept-Language"] == "en-US,en;q=0.9")
    }

    @Test func youtubeChannelPathSkipsPageFetch() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.ytFeed) }
        let d = try await detector(net).detect("https://www.youtube.com/channel/\(DetectFixture.channel)/videos")
        #expect(d.feedUrl == DetectFixture.ytFeedURL)
        #expect(net.calls == [DetectFixture.ytFeedURL])
    }

    @Test func youtubeFeedURLItself() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.ytFeed) }
        let d = try await detector(net).detect(DetectFixture.ytFeedURL)
        #expect(d.kind == .youtube)
        #expect(d.url == "https://www.youtube.com/channel/\(DetectFixture.channel)")
    }

    @Test func youtubeWithoutChannelId() async throws {
        let net = FakeNet { _ in .init(body: "<html>no id</html>") }
        await #expect(throws: FeedDetectionError("Could not find YouTube channel id")) {
            try await detector(net).detect("https://www.youtube.com/@nobody")
        }
    }

    @Test func youtubeFeedMissing() async throws {
        let net = FakeNet { u in u.contains("/feeds/") ? .init(status: 404) : .init(body: DetectFixture.ytChannelPage) }
        await #expect(throws: FeedDetectionError("YouTube feed not available for this channel")) {
            try await detector(net).detect("https://www.youtube.com/@fireship")
        }
    }

    @Test func alternateLinkFeed() async throws {
        let net = FakeNet { u in
            switch u {
            case "https://www.acme.com/": .init(body: DetectFixture.blogHome)
            case "https://www.acme.com/feed.xml?a=1&b=2": .init(body: DetectFixture.blogFeed)
            default: .init(status: 404)
            }
        }
        let d = try await detector(net).detect("https://www.acme.com/")
        #expect(d.feedUrl == "https://www.acme.com/feed.xml?a=1&b=2")
        #expect(d.url == "https://www.acme.com")
        #expect(d.kind == .rss)
    }

    @Test func alternateFallsThroughBrokenCandidates() async throws {
        let net = FakeNet { u in
            switch u {
            case "https://www.acme.com/": .init(body: DetectFixture.blogHome)
            case "https://www.acme.com/feed.xml?a=1&b=2": .init(body: "<html>not a feed</html>")
            case "https://cdn.acme.com/atom.xml": .init(body: DetectFixture.podcast)
            default: .init(status: 404)
            }
        }
        let d = try await detector(net).detect("https://www.acme.com/")
        #expect(d.feedUrl == "https://cdn.acme.com/atom.xml")
        #expect(d.kind == .podcast)
        // The site URL is the page's origin, not the feed's link.
        #expect(d.url == "https://www.acme.com")
    }

    @Test func pageFallback() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.newsPage) }
        let d = try await detector(net).detect("https://lab.example/news/?cat=ai#latest")
        #expect(d == DetectedFeed(title: "Lab News", url: "https://lab.example/news?cat=ai", feedUrl: "https://lab.example/news?cat=ai",
                                  kind: .page, group: "blogs"))
    }

    @Test func nothingFound() async throws {
        let net = FakeNet { _ in .init(body: "<html><body>Hello</body></html>") }
        await #expect(throws: FeedDetectionError("No RSS/Atom feed or article links found at that URL")) {
            try await detector(net).detect("https://empty.example/")
        }
    }

    @Test func wwwRetryOnNetworkError() async throws {
        let net = FakeNet { u in
            if u.hasPrefix("https://acme.com/") { throw URLError(.cannotFindHost) }
            return .init(body: DetectFixture.blogFeed)
        }
        let d = try await detector(net).detect("acme.com/feed.xml")
        #expect(net.calls == ["https://acme.com/feed.xml", "https://www.acme.com/feed.xml"])
        #expect(d.feedUrl == "https://www.acme.com/feed.xml")
    }

    @Test func wwwRetryOn404() async throws {
        let net = FakeNet { u in u.hasPrefix("https://www.") ? .init(status: 404) : .init(body: DetectFixture.blogFeed) }
        let d = try await detector(net).detect("www.acme.com/feed.xml")
        #expect(net.calls == ["https://www.acme.com/feed.xml", "https://acme.com/feed.xml"])
        #expect(d.feedUrl == "https://acme.com/feed.xml")
    }

    @Test func bothFailReportsOriginalStatus() async throws {
        let net = FakeNet { _ in .init(status: 503) }
        await #expect(throws: HTTPError.status(503)) { try await detector(net).detect("acme.com/news") }
    }

    @Test func networkErrorIsReadable() async throws {
        let net = FakeNet { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: FeedDetectionError("Could not reach acme.com")) { try await detector(net).detect("acme.com/news") }
    }

    @Test func timeoutIsNotRetried() async throws {
        let net = FakeNet { _ in throw HTTPError.timedOut }
        await #expect(throws: HTTPError.timedOut) { try await detector(net).detect("acme.com/news") }
        #expect(net.calls.count == 1)
    }

    @Test func noRetryOnSuccess() async throws {
        let net = FakeNet { _ in .init(body: DetectFixture.blogFeed) }
        _ = try await detector(net).detect("acme.com/feed.xml")
        #expect(net.calls.count == 1)
    }
}
