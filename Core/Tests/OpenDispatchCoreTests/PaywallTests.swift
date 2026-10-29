import Foundation
import Testing
@testable import OpenDispatchCore

private enum PaywallFixture {
    static func words(_ n: Int) -> String { (0..<n).map { "word\($0)" }.joined(separator: " ") }
    static func article(_ n: Int) -> String { "<p>\(words(n))</p>" }
    static func ld(_ json: String) -> String { "<script type=\"application/ld+json\">\(json)</script>" }
    static func page(head: String = "", body: String = "") -> String {
        "<html><head><title>T</title>\(head)</head><body>\(body)</body></html>"
    }
    static let notFree = ld(#"{"@type":"NewsArticle","isAccessibleForFree":false}"#)
    static let url = "https://news.example.com/a"
}

@Suite("Paywalls: detection")
struct PaywallDetectionTests {
    private typealias F = PaywallFixture

    @Test func aTeaserUnderAnInaccessibleForFreePageIsWalled() {
        #expect(PaywallDetection.isWalled(pageHTML: F.page(head: F.notFree), articleHTML: F.article(60), url: F.url))
        // The flag as a string, in any case, and on a part of the page.
        for json in [#"{"isAccessibleForFree":"False"}"#, #"{"isAccessibleForFree": "false"}"#,
                     #"{"@type":"NewsArticle","hasPart":{"@type":"WebPageElement","isAccessibleForFree":false,"cssSelector":".body"}}"#] {
            #expect(PaywallDetection.isWalled(pageHTML: F.page(head: F.ld(json)), articleHTML: F.article(60), url: F.url))
        }
    }

    @Test func theSameSignalOnAFullArticleIsNotWalled() {
        // A signed-in subscriber's page still says it isn't free, but carries the whole story.
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(head: F.notFree), articleHTML: F.article(900), url: F.url))
    }

    @Test func aFreePageIsNotWalled() {
        let free = F.page(head: F.ld(#"{"@type":"NewsArticle","isAccessibleForFree":true}"#), body: "<p>Short and free.</p>")
        #expect(!PaywallDetection.isWalled(pageHTML: free, articleHTML: F.article(40), url: F.url))
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(), articleHTML: nil, url: F.url))
    }

    @Test func aDeclaredWordCountSetsHowLongIsLongEnough() {
        let long = F.ld(#"{"isAccessibleForFree":false,"wordCount":2000}"#)
        // 400 words is plenty by the default gate, but a third of what the page says the story has.
        #expect(PaywallDetection.isWalled(pageHTML: F.page(head: long), articleHTML: F.article(400), url: F.url))
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(head: long), articleHTML: F.article(1300), url: F.url))
        // A short piece that came out whole is not cut short.
        let brief = F.ld(#"{"isAccessibleForFree":false,"wordCount":"250"}"#)
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(head: brief), articleHTML: F.article(240), url: F.url))
        #expect(PaywallDetection.isWalled(pageHTML: F.page(head: brief), articleHTML: F.article(100), url: F.url))
    }

    @Test func theContentTierMetaMarksLockedAndMeteredPages() {
        for tier in ["locked", "metered"] {
            let head = "<meta property=\"article:content_tier\" content=\"\(tier)\">"
            #expect(PaywallDetection.isWalled(pageHTML: F.page(head: head), articleHTML: F.article(80), url: F.url))
            let reversed = "<meta content=\"\(tier)\" property=\"article:content_tier\">"
            #expect(PaywallDetection.isWalled(pageHTML: F.page(head: reversed), articleHTML: F.article(80), url: F.url))
        }
        let free = "<meta property=\"article:content_tier\" content=\"free\">"
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(head: free), articleHTML: F.article(80), url: F.url))
    }

    @Test func aKnownSiteIsWalledWhenShort() {
        #expect(PaywallDetection.isWalled(pageHTML: F.page(), articleHTML: F.article(80), url: "https://www.nytimes.com/2026/10/28/a.html"))
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(), articleHTML: F.article(80), url: "https://blog.example.com/a"))
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(), articleHTML: F.article(800), url: "https://www.nytimes.com/2026/10/28/a.html"))
    }

    @Test func paywallMarkupAndPhrasesCount() {
        for body in ["<div class=\"tp-container-inner\"></div>", "<div class=\"tp-modal\"></div>", "<section id=\"article-paywall\"></section>",
                     "<div class=\"story Paywall-gate\"></div>", "<p>Subscribe to continue reading.</p>",
                     "<p>This article is for subscribers.</p>", "<p>Already a subscriber? Sign in.</p>"] {
            #expect(PaywallDetection.isWalled(pageHTML: F.page(body: body), articleHTML: F.article(80), url: F.url), "\(body)")
        }
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(body: "<div class=\"no-paywall\"></div>"), articleHTML: F.article(80), url: F.url))
        // A paywall library's strings in a script are on every page, free or not.
        let script = "<script>var t = \"Subscribe to continue reading\"; var c = \"paywall\";</script>"
        #expect(!PaywallDetection.isWalled(pageHTML: F.page(body: script), articleHTML: F.article(80), url: F.url))
    }

    @Test func aLoginWallInsteadOfAnArticleIsWalled() {
        let wall = "<p>Sign in to continue to the article.</p>"
        #expect(PaywallDetection.isWalled(pageHTML: F.page(), articleHTML: wall, url: F.url))
    }
}

@Suite("Paywalls: status and the book")
struct PaywallStatusTests {
    private let nyt = "https://www.nytimes.com/2026/10/28/a.html"
    private let blog = "https://writer.substack.com/p/a"

    @Test func sitesAreKeyedByKnownDomainOrHost() {
        #expect(Paywalls.site(of: "https://cooking.nytimes.com/recipes/1") == "nytimes.com")
        #expect(Paywalls.site(of: "https://www.example.com/a") == "example.com")
        #expect(Paywalls.site(of: blog) == "writer.substack.com")
        #expect(Paywalls.site(of: "not a url") == "")
    }

    @Test func aKnownSiteIsWalledAndMeteredOnceAFullArticleReadsThrough() {
        var book = PaywallBook()
        #expect(Paywalls.status(url: nyt, signedIn: [], book: book) == .walled)
        book.record(url: nyt, walled: false)
        #expect(Paywalls.status(url: nyt, signedIn: [], book: book) == .metered)
        // An aggregator's article is known by its outlet.
        #expect(Paywalls.status(url: "https://www.msn.com/a", publisher: "Barron's on MSN", signedIn: [], book: PaywallBook()) == .walled)
        #expect(Paywalls.status(url: "https://www.msn.com/a", publisher: "CBS News", signedIn: [], book: PaywallBook()) == .free)
    }

    @Test func aSiteIsLearnedAfterTwoWalledArticles() {
        var book = PaywallBook()
        book.record(url: blog, walled: true)
        #expect(Paywalls.status(url: blog, signedIn: [], book: book) == .free)
        book.record(url: "https://writer.substack.com/p/b", walled: true)
        #expect(Paywalls.status(url: blog, signedIn: [], book: book) == .walled)
        #expect(book.sites["writer.substack.com"]?.walled == 2)
        // Then one that read in full makes it metered; another Substack is untouched.
        book.record(url: blog, walled: false)
        #expect(Paywalls.status(url: blog, signedIn: [], book: book) == .metered)
        #expect(Paywalls.status(url: "https://other.substack.com/p/a", signedIn: [], book: book) == .free)
    }

    @Test func aFullReadIsOnlyCountedForSitesThatAreInTheBookOrKnown() {
        var book = PaywallBook()
        book.record(url: "https://free.example.com/a", walled: false)
        #expect(book.sites.isEmpty)
        book.record(url: nyt, walled: false)
        #expect(book.sites["nytimes.com"]?.full == 1)
        book.record(url: "", walled: true)
        #expect(book.sites.count == 1)
    }

    @Test func aSignInWins() {
        var book = PaywallBook()
        book.record(url: blog, walled: true)
        book.record(url: blog, walled: true)
        #expect(Paywalls.status(url: nyt, signedIn: ["nytimes.com"], book: book) == .signedIn)
        #expect(Paywalls.status(url: blog, signedIn: ["writer.substack.com"], book: book) == .signedIn)
        #expect(Paywalls.status(url: "https://cooking.nytimes.com/r", signedIn: ["nytimes.com"], book: book) == .signedIn)
    }

    @Test func declinedIsPerSiteAndSurvivesMoreReads() {
        var book = PaywallBook()
        #expect(!book.isDeclined(url: nyt))
        book.setDeclined(true, url: nyt)
        book.record(url: "https://cooking.nytimes.com/r", walled: true)
        #expect(book.isDeclined(url: nyt))
        #expect(!book.isDeclined(url: blog))
        book.setDeclined(false, url: nyt)
        #expect(!book.isDeclined(url: nyt))
        // Declining a site that was never walled puts it in the book, but it is still free.
        book.setDeclined(true, url: blog)
        #expect(Paywalls.status(url: blog, signedIn: [], book: book) == .free)
    }

    @Test func theBookRoundTripsThroughJSON() throws {
        var book = PaywallBook()
        book.record(url: nyt, walled: true, now: Date(timeIntervalSince1970: 1_790_000_000))
        book.setDeclined(true, url: nyt)
        let back = try JSONDecoder().decode(PaywallBook.self, from: JSONEncoder().encode(book))
        #expect(back == book)
    }
}

private final class LoaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func add(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}

/// Part of the serialized ExtractionFlowStubTests suite: these share its static URLProtocol routes.
extension ExtractionFlowStubTests {
    private typealias F = PaywallFixture

    static func fullPage(_ n: Int = 450) -> String {
        F.page(head: F.notFree, body: "<article>\(F.article(n))</article>")
    }
    static let teaserPage = F.page(head: F.notFree, body: "<article><p>\(para)</p></article>")

    private func extractor(signedIn: SignedInReader) -> DefaultContentExtractor {
        DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ExtractionStubProtocol.session(), signedIn: signedIn)
    }

    @Test func aTeaserPageComesBackPaywalled() async throws {
        ExtractionStubProtocol.reset(["https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.teaserPage)]])
        let out = try await extractor(signedIn: SignedInReader(isSignedIn: { _ in false }, html: { _ in nil }))
            .extractArticle(url: "https://e.com/a", feed: nil)
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
        #expect(out.paywalled)
        ExtractionStubProtocol.reset(["https://e.com/b": [.init(status: 200, headers: Self.html, body: Self.fullPage())]])
        let full = try await extractor(signedIn: SignedInReader(isSignedIn: { _ in false }, html: { _ in nil }))
            .extractArticle(url: "https://e.com/b", feed: nil)
        #expect(!full.paywalled)
    }

    @Test func theFeedsOwnCopyIsNotPaywalled() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.teaserPage)],
            "https://e.com/feed.xml": [.init(status: 200, headers: [:], body: "<rss/>")],
        ])
        let feedCopy = "<p>\(F.words(400))</p>"
        let ex = DefaultContentExtractor(parser: StubItemParser(html: feedCopy), readability: FakeReadability(),
                                         session: ExtractionStubProtocol.session(), signedIn: SignedInReader(isSignedIn: { _ in false }, html: { _ in nil }))
        let out = try await ex.extractArticle(url: "https://e.com/a", feed: FeedRef(feedUrl: "https://e.com/feed.xml", guid: "g"))
        #expect(out.contentHtml?.contains("word399") == true)
        #expect(!out.paywalled)
    }

    @Test func aSignedInSiteIsReadThroughTheLoader() async throws {
        ExtractionStubProtocol.reset(["https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.teaserPage)]])
        let log = LoaderLog()
        let reader = SignedInReader(isSignedIn: { $0.hasPrefix("https://e.com/") }, html: { url in log.add(url); return Self.fullPage() })
        let out = try await extractor(signedIn: reader).extractArticle(url: "https://e.com/a", feed: nil)
        #expect(out.contentHtml?.contains("word449") == true)
        #expect(!out.paywalled)
        #expect(log.all == ["https://e.com/a"])
        // The page itself was never fetched.
        #expect(ExtractionStubProtocol.requests().isEmpty)
    }

    @Test func aSiteThatIsNotSignedInIsNotLoadedInTheWebView() async throws {
        ExtractionStubProtocol.reset(["https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.fullPage())]])
        let log = LoaderLog()
        let reader = SignedInReader(isSignedIn: { _ in false }, html: { url in log.add(url); return Self.fullPage() })
        _ = try await extractor(signedIn: reader).extractArticle(url: "https://e.com/a", feed: nil)
        #expect(log.all.isEmpty)
    }

    @Test func aLapsedSignInFallsThroughToThePlainPage() async throws {
        ExtractionStubProtocol.reset(["https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.teaserPage)]])
        let log = LoaderLog()
        // The signed-in view is still shown the teaser (and a load that fails returns nothing): the page is fetched as for anyone.
        for loaded in [Self.teaserPage, nil] {
            let reader = SignedInReader(isSignedIn: { _ in true }, html: { url in log.add(url); return loaded })
            let out = try await extractor(signedIn: reader).extractArticle(url: "https://e.com/a", feed: nil)
            #expect(out.contentHtml?.contains("Stubbed article text") == true)
            #expect(out.paywalled)
        }
        #expect(log.all.count == 2)
    }

    @Test func postsAreNeverReadInTheSignedInView() async throws {
        let log = LoaderLog()
        let reader = SignedInReader(isSignedIn: { _ in true }, html: { url in log.add(url); return Self.fullPage() })
        ExtractionStubProtocol.reset([:])
        _ = try? await extractor(signedIn: reader).extractArticle(url: "https://x.com/someone/status/123", feed: nil)
        _ = try? await extractor(signedIn: reader).extractArticle(url: "https://www.reddit.com/r/swift/comments/abc/title/", feed: nil)
        _ = try? await extractor(signedIn: reader).extractArticle(url: "https://news.ycombinator.com/item?id=1", feed: nil)
        #expect(log.all.isEmpty)
    }

    @Test func contentServiceDoesNotCacheAPaywalledResult() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, url: "https://e.com", feedUrl: "https://e.com/feed-pw.xml")
        let up = try Fixture.items(db, sourceId: src.id, [ParsedItem(guid: "g", url: "https://e.com/a", title: "A", publishedAt: Fixture.base)])
        let id = try #require(up.first?.id)
        ExtractionStubProtocol.reset(["https://e.com/a": [.init(status: 200, headers: Self.html, body: Self.teaserPage)]])
        let service = ContentService(database: db, extractor: extractor(signedIn: SignedInReader(isSignedIn: { _ in false }, html: { _ in nil })))
        let out = try await service.content(forItem: id)
        #expect(out.paywalled)
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
        #expect(try await db.itemRecord(id: id)?.contentHtml == nil)

        // After signing in the article is read again, in full, and cached.
        let reader = SignedInReader(isSignedIn: { _ in true }, html: { _ in Self.fullPage() })
        let signedIn = ContentService(database: db, extractor: extractor(signedIn: reader))
        let full = try await signedIn.content(forItem: id)
        #expect(!full.paywalled)
        #expect(full.contentHtml?.contains("word449") == true)
        #expect(try await db.itemRecord(id: id)?.contentHtml == full.contentHtml)
    }
}
