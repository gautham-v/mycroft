import Foundation
import Testing
@testable import OpenDispatchCore

// Fixtures are inline HTML strings (no network).

enum ScrapeFixture {
    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    struct Route: Sendable {
        var status: Int = 200
        var body: String = ""
        var contentType: String? = "text/html; charset=utf-8"
        var finalURL: String?
        var fails = false
    }

    /// A fake transport over fixed routes; unknown URLs fail like a network error.
    static func fetch(_ routes: [String: Route], log: RequestLog? = nil) -> PageScraperFetch {
        { req in
            await log?.add(req)
            guard let r = routes[req.url], !r.fails else { throw URLError(.cannotConnectToHost) }
            var headers: [String: String] = [:]
            if let ct = r.contentType { headers["Content-Type"] = ct }
            let url = URL(string: r.finalURL ?? req.url)!
            let res = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(r.body.utf8), res)
        }
    }

    actor RequestLog {
        var requests: [PageFetchRequest] = []
        func add(_ r: PageFetchRequest) { requests.append(r) }
    }

    static let newsListing = """
    <html><head><title>Newsroom \\ Anthropic</title></head><body>
    <nav>
      <a href="/">Home</a>
      <a href="/news">News</a>
      <a href="/news/policy">Policy</a>
      <a href="/about">About</a>
      <a href="mailto:press@anthropic.com">Press</a>
      <a href="#main">Skip</a>
      <a href="https://twitter.com/anthropicai">Twitter</a>
    </nav>
    <main>
      <a href="/news/claude-duet?utm_source=x#top"><h3>Claude Duet</h3></a>
      <a href="https://anthropic.com/news/claude-duet/">Read more</a>
      <a href="https://www.anthropic.com/news/singapore-office">Singapore office opening</a>
      <a href="/news/2025">2025 in review</a>
      <a href="/news/tag/research">Research</a>
      <a href="/news/2">Next page</a>
      <a href="/de/news/claude-duet">Claude Duet (Deutsch)</a>
      <a href="/news/feed.xml">RSS</a>
      <a href="/news/claude-duet/comments">Comments</a>
      <a href="/news/caf%C3%A9-launch">Cafe launch</a>
      <a href="/news/bad%E0%A4%A">Broken</a>
    </main></body></html>
    """
}

@Suite("Scraping: article links")
struct ScrapingLinkTests {
    @Test func strictLinksOneSegmentBelowListing() {
        let links = PageScraping.findArticleLinks(html: ScrapeFixture.newsListing, pageURL: "https://www.anthropic.com/news")
        #expect(links == [
            "https://www.anthropic.com/news/claude-duet",
            "https://www.anthropic.com/news/singapore-office",
            "https://www.anthropic.com/news/2025",
            "https://www.anthropic.com/news/caf%C3%A9-launch",
        ])
    }

    @Test func defaultScraperDelegatesToPureHelpers() {
        let s = DefaultPageScraper()
        #expect(s.findArticleLinks(html: ScrapeFixture.newsListing, pageURL: "https://www.anthropic.com/news").count == 4)
        #expect(s.listingTitle(html: ScrapeFixture.newsListing, pageURL: "https://www.anthropic.com/news") == "Anthropic Newsroom")
    }

    @Test func fallbackPicksMostCommonSlugParentAtRoot() {
        let html = """
        <a href="/pricing">Pricing</a><a href="/docs/getting-started">Docs</a>
        <a href="/blog/first-post">First</a><a href="/blog/second-post/">Second</a>
        <a href="/blog/category/news">News</a><a href="/blog/third-post">Third</a>
        <a href="/team/jane-doe">Jane</a>
        """
        let links = PageScraping.findArticleLinks(html: html, pageURL: "https://example.com/")
        #expect(links == ["https://example.com/blog/first-post", "https://example.com/blog/second-post", "https://example.com/blog/third-post"])
    }

    @Test func fallbackTieGoesToEarliestGroup() {
        let html = """
        <a href="/a/one-x">1</a><a href="/b/two-x">2</a><a href="/a/three-x">3</a><a href="/b/four-x">4</a>
        """
        #expect(PageScraping.findArticleLinks(html: html, pageURL: "https://example.com") == [
            "https://example.com/a/one-x", "https://example.com/a/three-x",
        ])
    }

    @Test func fallbackNeedsAtLeastTwoLinks() {
        let html = #"<a href="/blog/only-post">Only</a><a href="/about">About</a>"#
        #expect(PageScraping.findArticleLinks(html: html, pageURL: "https://example.com/").isEmpty)
    }

    @Test func strictFallsBackWhenNothingBelowListing() {
        // Listing /resources/articles but articles live at /blog/<slug>.
        let html = #"<a href="/blog/post-one">1</a><a href="/blog/post-two">2</a><a href="/resources/articles/x">X</a>"#
        let links = PageScraping.findArticleLinks(html: html, pageURL: "https://example.com/resources/articles")
        // "/resources/articles/x": last segment "x" is a one-letter label link with text "X" → excluded.
        #expect(links == ["https://example.com/blog/post-one", "https://example.com/blog/post-two"])
    }

    @Test func baseHrefResolvesRelativeLinks() {
        let html = #"<head><base href="https://example.com/news/"></head><a href="alpha-post">A</a><a href="beta-post">B</a>"#
        #expect(PageScraping.findArticleLinks(html: html, pageURL: "https://example.com/news") == [
            "https://example.com/news/alpha-post", "https://example.com/news/beta-post",
        ])
    }

    @Test func xProfileKeepsOnlyStatusLinks() {
        let html = """
        <a href="/kun/status/111">post</a><a href="/kun/media">Media</a><a href="/kun/with_replies">Replies</a>
        <a href="https://x.com/kun/status/222?s=20">post</a><a href="/compose/post">Post</a>
        <a href="https://twitter.com/kun/status/333">elsewhere</a>
        """
        #expect(PageScraping.findArticleLinks(html: html, pageURL: "https://x.com/kun") == [
            "https://x.com/kun/status/111", "https://x.com/kun/status/222",
        ])
    }

    @Test func caps30Links() {
        let html = (1...40).map { #"<a href="/news/post-\#($0)">Post number \#($0)</a>"# }.joined()
        let links = PageScraping.findArticleLinks(html: html, pageURL: "https://example.com/news")
        #expect(links.count == 30)
        #expect(links.first == "https://example.com/news/post-1")
    }

    @Test func canonicalURL() {
        #expect(PageScraping.canonicalURL("https://Example.com/a/b/?q=1#x") == "https://example.com/a/b")
        #expect(PageScraping.canonicalURL("https://example.com") == "https://example.com/")
        #expect(PageScraping.canonicalURL("https://example.com:443/x") == "https://example.com/x")
        #expect(PageScraping.canonicalURL("http://example.com:8080/x//") == "http://example.com:8080/x")
        #expect(PageScraping.canonicalURL("not a url") == nil)
    }
}

@Suite("Scraping: titles and metadata")
struct ScrapingMetaTests {
    @Test func listingTitleVariants() {
        let og = #"<head><meta property="og:title" content="Newsroom"><meta property="og:site_name" content="Anthropic"></head>"#
        #expect(PageScraping.listingTitle(html: og, pageURL: "https://www.anthropic.com/news") == "Anthropic Newsroom")

        let ogHasSite = #"<head><meta property="og:title" content="Claude Articles"><meta property="og:site_name" content="Claude"><title>Articles | Claude</title></head>"#
        #expect(PageScraping.listingTitle(html: ogHasSite, pageURL: "https://claude.com/resources/articles") == "Claude Articles")

        let titleOnly = "<title>Engineering Blog — Acme Inc</title>"
        #expect(PageScraping.listingTitle(html: titleOnly, pageURL: "https://acme.com/blog") == "Acme Inc Engineering Blog")

        let longSite = "<title>Posts | The Very Long Site Name Here</title>"
        #expect(PageScraping.listingTitle(html: longSite, pageURL: "https://acme.com/blog") == "Posts | The Very Long Site Name Here")

        #expect(PageScraping.listingTitle(html: "<p>nothing</p>", pageURL: "https://www.acme.com/blog") == "acme.com")

        let x = #"<meta property="og:title" content="Kun Chen (@kunchenguid) on X"><meta property="og:site_name" content="X">"#
        #expect(PageScraping.listingTitle(html: x, pageURL: "https://x.com/kunchenguid") == "Kun Chen (@kunchenguid) on X")
    }

    @Test func articleMetaFromOpenGraphAndJSONLD() throws {
        let html = """
        <html><head>
        <title>Singapore office opening | Anthropic</title>
        <meta property="og:title" content="Singapore office opening | Anthropic">
        <meta property="og:site_name" content="Anthropic">
        <meta property="og:type" content="Article">
        <meta name="description" content="  We are   opening an office
          in Singapore. ">
        <meta property="og:image" content="/images/sg.png">
        <script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebPage","name":"x"},
          {"@type":["BlogPosting"],"headline":"Ignored","datePublished":"2026-10-21",
           "author":[{"@type":"Person","name":"Jane Doe"},{"@type":"Organization","name":"Anthropic"},"https://x.com/jane","Bob"]}
        ]}
        </script>
        </head><body><h1>Heading</h1><time datetime="2020-01-01">old</time></body></html>
        """
        let now = ScrapeFixture.utc(2026, 10, 25)
        let m = PageScraping.extractArticleMeta(html: html, pageURL: "https://www.anthropic.com/news/singapore-office", now: now)
        #expect(m.title == "Singapore office opening")
        #expect(m.summary == "We are opening an office in Singapore.")
        #expect(m.author == "Jane Doe, Bob")
        #expect(m.publishedAt == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(m.thumbnailUrl == "https://www.anthropic.com/images/sg.png")
        #expect(m.ogType == "article")
    }

    @Test func articleMetaFallbacks() {
        let html = """
        <head><title>Hello world - My Blog</title><meta name="author" content="https://me.example"></head>
        <body><article><time datetime="2026-09-01T08:15:00Z">Sep 1</time></article>
        <script type="application/ld+json">not json</script></body>
        """
        let m = PageScraping.extractArticleMeta(html: html, pageURL: "https://blog.example/p/hello-world", now: ScrapeFixture.utc(2026, 10, 25))
        #expect(m.title == "Hello world")
        #expect(m.author == nil)
        #expect(m.publishedAt == ScrapeFixture.utc(2026, 9, 1, 8, 15))
        #expect(m.summary == nil)
        #expect(m.thumbnailUrl == nil)
        #expect(m.ogType == nil)
    }

    @Test func titleClippedAndTwitterImage() {
        let long = String(repeating: "word ", count: 100)
        let html = #"<meta property="og:title" content="\#(long)"><meta name="twitter:image" content="https://cdn.example/x.jpg"><meta property="og:image" content="javascript:alert(1)">"#
        let m = PageScraping.extractArticleMeta(html: html, pageURL: "https://example.com/a/b-c")
        #expect(m.title?.count == 300)
        #expect(m.title?.hasSuffix("word…") == true)
        // og:image wins the lookup but isn't http(s), so there is no image (same as the web).
        #expect(m.thumbnailUrl == nil)
    }

    @Test func tweetMeta() {
        let html = #"""
        <head>
        <meta property="og:title" content="Kun Chen (@kunchenguid) on X">
        <meta property="og:description" content="First paragraph here.

        Second paragraph.">
        <meta property="og:image" content="https://pbs.twimg.com/x.jpg">
        </head><body><script>window.__DATA__="{\"quoted_tweet_results\":{\"result\":{\"avatar\":{\"image_url\":\"https://pbs.twimg.com/profile_images/1/a_normal.jpg\"},\"core\":{\"name\":\"Jane \\u00e9 Doe\",\"screen_name\":\"jane\"},\"legacy\":{\"full_text\":\"Quoted line one\\nline two\"}}}}"</script></body>
        """#
        let m = PageScraping.extractArticleMeta(html: html, pageURL: "https://x.com/kunchenguid/status/123")
        #expect(m.title == "First paragraph here.")
        #expect(m.author == "Kun Chen (@kunchenguid)")
        #expect(m.summary == "Quoting Jane é Doe: Quoted line one")
        #expect(m.quoteAvatarUrl == "https://pbs.twimg.com/profile_images/1/a_normal.jpg")
        #expect(m.thumbnailUrl == nil)
        #expect(m.ogType == "article")
    }

    @Test func mediaOnlyTweetTitle() {
        func meta(_ image: String) -> ArticleMeta {
            let html = #"<head><meta property="og:title" content="almonk (@almonk) on X"><meta property="og:description" content="almonk (@almonk) on X"><meta property="og:image" content="\#(image)"></head>"#
            return PageScraping.extractArticleMeta(html: html, pageURL: "https://x.com/almonk/status/1")
        }
        func title(_ image: String) -> String? { meta(image).title }
        #expect(meta("https://pbs.twimg.com/media/HVl?format=webp&amp;name=large").thumbnailUrl == "https://pbs.twimg.com/media/HVl?format=webp&name=small")
        #expect(meta("https://pbs.twimg.com/profile_images/1/a_400x400.jpg").thumbnailUrl == nil)
        #expect(title("https://pbs.twimg.com/media/HVl?format=webp&amp;name=large") == "Photo")
        #expect(title("https://pbs.twimg.com/amplify_video_thumb/2/img/B?format=webp") == "Video")
        #expect(title("https://pbs.twimg.com/tweet_video_thumb/C.jpg") == "GIF")
        #expect(title("https://pbs.twimg.com/profile_images/1/a_400x400.jpg") == "almonk (@almonk) on X")
    }

    @Test func pageImageHelpers() {
        let html = #"""
        <head><script type="application/ld+json">[{"@type":"NewsArticle","image":[{"url":"img/a.png"}]}]</script></head>
        """#
        #expect(PageMeta.imageFromHTML(html, pageURL: "https://example.com/news/x") == "https://example.com/news/img/a.png")
        #expect(PageMeta.imageFromMetaMap(["OG:Image": "//cdn.example/i.png", "x": 1], pageURL: "https://example.com/a") == "https://cdn.example/i.png")
        #expect(PageMeta.imageFromMetaMap([:], pageURL: "https://example.com/a") == nil)
    }

    @Test func metaReaderFirstWinsCaseInsensitive() throws {
        let doc = try SwiftSoupParse.doc(#"<meta name="Description" content="one"><meta property="description" content="two"><meta itemprop="x" content="  ">"#)
        let meta = PageMeta.meta(in: doc)
        #expect(meta("DESCRIPTION") == "one")
        #expect(meta("x") == nil)
        #expect(meta("missing", "description") == "one")
    }
}

import SwiftSoup
private enum SwiftSoupParse {
    static func doc(_ html: String) throws -> Document { try SwiftSoup.parse(html, "https://example.com/") }
}

@Suite("Scraping: dates")
struct ScrapingDateTests {
    let now = ScrapeFixture.utc(2026, 10, 25, 18)

    @Test func dateOnlyIsNoonUTC() {
        #expect(PageMeta.toDate("2026-10-21", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(PageMeta.toDate("October 21, 2026", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(PageMeta.toDate("Oct 21, 2026", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(PageMeta.toDate("21 October 2026", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(PageMeta.toDate("Wed, 21 Oct 2026 GMT", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
        #expect(PageMeta.toDate("2026-10", now: now) == ScrapeFixture.utc(2026, 10, 1, 12))
        #expect(PageMeta.toDate("2026/10/21", now: now) == ScrapeFixture.utc(2026, 10, 21, 12))
    }

    @Test func dateOnlyTodayNeverInFuture() {
        let morning = ScrapeFixture.utc(2026, 10, 25, 6)
        #expect(PageMeta.toDate("2026-10-25", now: morning) == morning)
        #expect(PageMeta.toDate("2026-10-26", now: morning) == morning)
    }

    @Test func fullTimestampsKept() {
        #expect(PageMeta.toDate("2026-10-21T10:30:00Z", now: now) == ScrapeFixture.utc(2026, 10, 21, 10, 30))
        let frac = PageMeta.toDate("2026-10-21T10:30:00.250+02:00", now: now)
        #expect(abs((frac?.timeIntervalSince(ScrapeFixture.utc(2026, 10, 21, 8, 30)) ?? 99) - 0.25) < 0.001)
        #expect(PageMeta.toDate("Wed, 21 Oct 2026 10:00:00 +0200", now: now) == ScrapeFixture.utc(2026, 10, 21, 8))
        #expect(PageMeta.toDate("Wed, 21 Oct 2026 10:00:00 GMT", now: now) == ScrapeFixture.utc(2026, 10, 21, 10))
        #expect(PageMeta.toDate("21 Oct 2026 10:00:00 PDT", now: now) == ScrapeFixture.utc(2026, 10, 21, 17))
        #expect(PageMeta.toDate("Wed Oct 21 2026 10:00:00 GMT+0000 (Coordinated Universal Time)", now: now) == ScrapeFixture.utc(2026, 10, 21, 10))
    }

    @Test func nonsenseRejected() {
        #expect(PageMeta.toDate(nil, now: now) == nil)
        #expect(PageMeta.toDate("   ", now: now) == nil)
        #expect(PageMeta.toDate("yesterday", now: now) == nil)
        #expect(PageMeta.toDate("1990-01-01", now: now) == nil)
        #expect(PageMeta.toDate("2026-11-30T00:00:00Z", now: now) == nil)
        #expect(PageMeta.toDate("2026-02-30", now: now) == nil)
        // Up to two days ahead is tolerated for full timestamps (clock skew, time zones).
        #expect(PageMeta.toDate("2026-10-26T12:00:00Z", now: now) == ScrapeFixture.utc(2026, 10, 26, 12))
    }
}

@Suite("Scraping: scrape and page images")
struct ScrapingNetworkTests {
    typealias Route = ScrapeFixture.Route

    static let listing = """
    <title>Blog | Example</title>
    <a href="/blog/known-post">Known</a>
    <a href="/blog/dated-post">Dated</a>
    <a href="/blog/undated-post">Undated</a>
    <a href="/blog/gone-post">Gone</a>
    <a href="/blog/flaky-post">Flaky</a>
    <a href="/blog/pdf-post">PDF</a>
    <a href="/blog/landing-page">Landing</a>
    <a href="/blog/timeout-post">Timeout</a>
    """

    static func article(_ title: String, date: String? = nil, type: String = "article") -> String {
        """
        <head><meta property="og:title" content="\(title)"><meta property="og:type" content="\(type)">
        \(date.map { #"<meta property="article:published_time" content="\#($0)">"# } ?? "")
        <meta property="og:image" content="/img/\(title).png"></head>
        """
    }

    static let routes: [String: Route] = [
        "https://example.com/blog": Route(body: listing, finalURL: "https://www.example.com/blog/"),
        "https://www.example.com/blog/known-post": Route(body: article("Known")),
        "https://www.example.com/blog/dated-post": Route(body: article("Dated", date: "2026-10-20T09:00:00Z")),
        "https://www.example.com/blog/undated-post": Route(body: article("Undated"), finalURL: "https://cdn.example.com/u"),
        "https://www.example.com/blog/gone-post": Route(status: 404),
        "https://www.example.com/blog/flaky-post": Route(status: 503),
        "https://www.example.com/blog/pdf-post": Route(body: "%PDF", contentType: "application/pdf"),
        "https://www.example.com/blog/landing-page": Route(body: article("Landing", type: "website")),
        "https://www.example.com/blog/timeout-post": Route(fails: true),
    ]

    @Test func scrapeBuildsItemsAndProcessed() async throws {
        let log = ScrapeFixture.RequestLog()
        let scraper = DefaultPageScraper(fetch: ScrapeFixture.fetch(Self.routes, log: log))
        let before = Date()
        let r = try await scraper.scrape(listingURL: "https://example.com/blog", known: ["https://www.example.com/blog/known-post"], budget: nil)
        #expect(r.listingUrl == "https://www.example.com/blog/")
        #expect(r.links.count == 8)
        #expect(r.links.first == "https://www.example.com/blog/known-post")
        #expect(r.items.map(\.title) == ["Dated", "Undated"])
        #expect(r.processed == [
            "https://www.example.com/blog/dated-post", "https://www.example.com/blog/undated-post",
            "https://www.example.com/blog/gone-post", "https://www.example.com/blog/pdf-post",
            "https://www.example.com/blog/landing-page",
        ])
        let dated = try #require(r.items.first)
        #expect(dated.guid == "https://www.example.com/blog/dated-post")
        #expect(dated.url == dated.guid)
        #expect(dated.publishedAt == ScrapeFixture.utc(2026, 10, 20, 9))
        #expect(dated.thumbnailUrl == "https://www.example.com/img/Dated.png")
        let undated = r.items[1]
        // First-seen time minus page position (index 2) seconds; image resolved against the final URL.
        #expect(abs(undated.publishedAt.timeIntervalSince(before) + 2) < 5)
        #expect(undated.thumbnailUrl == "https://cdn.example.com/img/Undated.png")

        let reqs = await log.requests
        #expect(!reqs.contains { $0.url.hasSuffix("known-post") })
        #expect(reqs.first?.timeout == 15)
        #expect(reqs.first?.headers["Accept"] == "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5")
        #expect(reqs.dropFirst().allSatisfy { $0.timeout == 10 && !$0.headOnly })
    }

    @Test func scrapeErrors() async {
        let scraper = DefaultPageScraper(fetch: ScrapeFixture.fetch([
            "https://a.example/news": Route(status: 403),
            "https://b.example/news": Route(body: "<p>No links</p>"),
        ]))
        await #expect(throws: HTTPError.status(403)) {
            try await scraper.scrape(listingURL: "https://a.example/news", known: [], budget: nil)
        }
        await #expect(throws: PageScraperError.noArticleLinks) {
            try await scraper.scrape(listingURL: "https://b.example/news", known: [], budget: nil)
        }
        #expect(PageScraperError.noArticleLinks.localizedDescription == "No article links found on the page")
        #expect(HTTP.message(HTTPError.status(403)) == "HTTP 403")
    }

    @Test func scrapeZeroBudgetFetchesNothing() async throws {
        let scraper = DefaultPageScraper(fetch: ScrapeFixture.fetch(Self.routes))
        let r = try await scraper.scrape(listingURL: "https://example.com/blog", known: [], budget: 0)
        #expect(r.links.count == 8)
        #expect(r.items.isEmpty)
        #expect(r.processed.isEmpty)
    }

    @Test func fetchPageImageOutcomes() async {
        let jinaBody = #"{"code":200,"data":{"url":"https://blocked.example/post","metadata":{"og:image":"/share.png"}}}"#
        let log = ScrapeFixture.RequestLog()
        let scraper = DefaultPageScraper(fetch: ScrapeFixture.fetch([
            "https://ok.example/p": Route(body: #"<head><meta property="og:image" content="/a.jpg"></head>"#),
            "https://none.example/p": Route(body: "<head><title>x</title></head>"),
            "https://blocked.example/post": Route(status: 403),
            "https://r.jina.ai/https://blocked.example/post": Route(body: jinaBody, contentType: "application/json"),
            "https://limited.example/p": Route(status: 429),
            "https://missing.example/p": Route(status: 404),
            "https://img.example/p.png": Route(body: "PNG", contentType: "image/png"),
            "https://blocked2.example/p": Route(status: 401),
            "https://r.jina.ai/https://blocked2.example/p": Route(status: 502),
        ], log: log))
        #expect(await scraper.fetchPageImage(url: "https://ok.example/p", timeout: 6) == PageImageResult(image: "https://ok.example/a.jpg", final: true))
        #expect(await scraper.fetchPageImage(url: "https://none.example/p", timeout: 6) == PageImageResult(image: nil, final: true))
        #expect(await scraper.fetchPageImage(url: "https://blocked.example/post", timeout: 6) == PageImageResult(image: "https://blocked.example/share.png", final: true))
        #expect(await scraper.fetchPageImage(url: "https://limited.example/p", timeout: 6) == PageImageResult(image: nil, final: false))
        #expect(await scraper.fetchPageImage(url: "https://missing.example/p", timeout: 6) == PageImageResult(image: nil, final: true))
        #expect(await scraper.fetchPageImage(url: "https://img.example/p.png", timeout: 6) == PageImageResult(image: nil, final: true))
        #expect(await scraper.fetchPageImage(url: "https://unreachable.example/p", timeout: 6) == PageImageResult(image: nil, final: true))
        #expect(await scraper.fetchPageImage(url: "https://blocked2.example/p", timeout: 6) == PageImageResult(image: nil, final: false))

        let reqs = await log.requests
        let first = reqs.first { $0.url == "https://ok.example/p" }
        #expect(first?.headOnly == true)
        #expect(first?.headers["User-Agent"]?.contains("Chrome") == true)
        let jina = reqs.first { $0.url.hasPrefix("https://r.jina.ai/") }
        #expect(jina?.headers["X-Target-Selector"] == "head")
    }

    @Test func fetchPageImagesBatch() async {
        var routes: [String: Route] = [:]
        for i in 0..<6 { routes["https://e.example/\(i)"] = Route(body: #"<meta property="og:image" content="/\#(i).png">"#) }
        let scraper = DefaultPageScraper(fetch: ScrapeFixture.fetch(routes))
        let targets = (0..<6).map { ThumbnailTarget(id: Int64($0), url: "https://e.example/\($0)") }
        let out = await scraper.fetchPageImages(targets)
        #expect(out.count == 6)
        #expect(Set(out.map(\.target.id)) == Set(0..<6))
        #expect(out.allSatisfy { $0.result.image == "https://e.example/\($0.target.id).png" })
        #expect(await scraper.fetchPageImages(targets, budget: 0).isEmpty)
    }

    @Test func headEndDetection() {
        #expect(DefaultPageScraper.headEnd(Array("<html><head><title>x</title></HEAD >".utf8)) == 28)
        #expect(DefaultPageScraper.headEnd(Array("<html><head><title>x</title>".utf8)) == nil)
        #expect(DefaultPageScraper.headEnd(Array(">".utf8)) == nil)
    }
}

@Suite("Scraping: RSC payload and payload videos")
struct RSCPayloadTests {
    /// Builds `self.__next_f.push([1,"<chunk>"])` scripts with the chunk JSON-escaped.
    static func push(_ chunks: [String]) -> String {
        chunks.map { chunk in
            let data = try! JSONSerialization.data(withJSONObject: [chunk], options: [.withoutEscapingSlashes])
            let arr = String(decoding: data, as: UTF8.self)  // ["..."]
            return "<script>self.__next_f.push([1,\(arr.dropFirst().dropLast())])</script>"
        }.joined()
    }

    @Test func payloadJoinsChunks() {
        let html = "<script>self.__next_f.push([0])</script>" + Self.push(["1:{\"a\":", "1}\n"])
        #expect(RSCPayload.payload(html) == "1:{\"a\":1}\n")
        #expect(RSCPayload.payload("<p>plain</p>") == "")
    }

    @Test func balancedEndHandlesStrings() {
        let t = RSCPayload.bytes(#"x{"a":"}{[","b":[1,{"c":2}]}tail"#)
        #expect(RSCPayload.balancedEnd(t, 1) == t.count - 4)
        #expect(RSCPayload.balancedEnd(t, 0) == -1)
        #expect(RSCPayload.balancedEnd(RSCPayload.bytes("{\"a\":1"), 0) == -1)
    }

    @Test func enclosingObjectFindsInnermostAccepted() throws {
        let text = RSCPayload.bytes(#"0:{"outer":{"reactComponent":"DotcomChart","data":{"spec":"$5"}},"x":1}"#)
        let pos = try #require(RSCPayload.offsets(of: "\"spec\"", in: text).first)
        let inner = try #require(RSCPayload.enclosingObject(in: text, at: pos) { _ in true })
        #expect(inner.value["spec"] as? String == "$5")
        let chart = try #require(RSCPayload.enclosingObject(in: text, at: pos) { $0["reactComponent"] as? String == "DotcomChart" })
        #expect(chart.start == 11)
        #expect(RSCPayload.enclosingObject(in: text, at: pos) { $0["nope"] != nil } == nil)
    }

    @Test func resolveRowsAndEscapes() throws {
        let text = RSCPayload.bytes("0:[\"$\",\"div\"]\n5:{\"mark\":\"bar\",\"gone\":\"$undefined\",\"cost\":\"$$10\"}\na:[1,\"$undefined\"]\n")
        let r = try #require(RSCPayload.resolve(["spec": "$5", "list": "$a", "plain": "x"], in: text) as? [String: Any])
        let spec = try #require(r["spec"] as? [String: Any])
        #expect(spec["mark"] as? String == "bar")
        #expect(spec["cost"] as? String == "$10")
        #expect(spec["gone"] == nil)
        let list = try #require(r["list"] as? [Any])
        #expect(list.count == 2)
        #expect(list[1] is NSNull)
        #expect(r["plain"] as? String == "x")
        #expect(RSCPayload.resolve("$undefined", in: text) == nil)
    }

    @Test func textBeforeUsesRowReference() {
        let para = "This is a long paragraph of rendered text that precedes the player."
        let text = "0:[\"$\",\"p\",null,{\"children\":\"\(para)\"}]\n1:[\"$\",\"div\",null,{\"children\":\"$L1e9\"}]\n1e9:{\"videoEmbedUrl\":\"https://player.vimeo.com/video/42\"}\n"
        let bytes = RSCPayload.bytes(text)
        let pos = RSCPayload.offsets(of: "{\"videoEmbedUrl\"", in: bytes).first ?? 0
        #expect(RSCPayload.textBefore(bytes, pos) == para)
    }

    @Test func findsPayloadVideos() {
        let para = "Watch the demo below to see how the new model handles long tasks."
        let rows = [
            "0:[\"$\",\"p\",null,{\"children\":\"\(para)\"}]\n",
            "1:{\"altText\":\"Demo video\",\"videoEmbedUrl\":\"https://player.vimeo.com/video/123456?h=abc\",\"videoEmbedTitle\":\"Demo\",",
            "\"posterImage\":{\"title\":\"Demo poster\",\"file\":{\"url\":\"https://images.ctfassets.net/x/poster-demo.jpg\"}}}\n",
            "2:{\"videoEmbedUrl\":\"https://player.vimeo.com/video/123456\"}\n",
            "3:{\"videoEmbedUrl\":\"https://example.com/not-an-embed\"}\n",
            "4:{\"videoEmbedUrl\" : \"https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ\",\"posterImage\":{\"file\":{\"fileName\":\"yt.png\"}}}\n",
        ]
        let html = "<div>videoEmbedUrl</div>" + Self.push(rows)
        let videos = PayloadVideos.find(in: html)
        #expect(videos.count == 2)
        #expect(videos.first == PayloadVideo(
            src: "https://player.vimeo.com/video/123456?h=abc", key: "123456", title: "Demo",
            names: ["Demo video", "Demo poster"], posterFile: "poster-demo.jpg", anchor: para))
        #expect(videos.last?.key == "dQw4w9WgXcQ")
        #expect(videos.last?.posterFile == "yt.png")
        #expect(PayloadVideos.find(in: "<p>no players</p>").isEmpty)
    }
}
