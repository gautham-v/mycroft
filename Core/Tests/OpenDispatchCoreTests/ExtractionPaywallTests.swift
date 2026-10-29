import Foundation
import Testing
@testable import OpenDispatchCore

/// Paywall and access defects found by comparing the reader with the original pages (Tom's Hardware, Japan Times, Le Monde,
/// Nature, LWN, The New Yorker, Pitchfork, Politico).
/// URLProtocol stub with its own routes (the shared one is reset by another suite), one canned response per URL.
final class PaywallStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [PaywallStubProtocol.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let canned = Self.routes[request.url?.absoluteString ?? ""] ?? (500, "")
        let res = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: canned.status, httpVersion: "HTTP/1.1",
                                  headerFields: ["Content-Type": "text/html"])
        if let res { client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Extraction: paywalls")
struct ExtractionPaywallTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    static func ld(_ json: String) -> String { "<script type=\"application/ld+json\">\(json)</script>" }
    static func page(head: String = "", body: String = "") -> String { "<html><head><title>T</title>\(head)</head><body>\(body)</body></html>" }
    static func words(_ n: Int) -> String { (0..<n).map { "word\($0)" }.joined(separator: " ") }

    // MARK: Kiosq (Tom's Hardware)

    @Test func paragraphsHiddenFromAssistiveTechnologyBesideVisibleOnesAreTheStory() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>
        <p>\(Self.para) FIRST</p>
        <p aria-hidden="true" class="kiosq-b">\(Self.para) SECOND</p>
        <div id="ad-unit-2" class="ad-unit"></div>
        <p aria-hidden="true" class="kiosq-b">\(Self.para) THIRD</p>
        </article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("FIRST") && body.contains("SECOND") && body.contains("THIRD"))
    }

    @Test func ariaHiddenGlyphsAndShortLinesStayHidden() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>
        <p>\(Self.para)</p>
        <p aria-hidden="true">Advertisement</p>
        <p aria-hidden="true" class="price">\(Self.para) LONELY</p>
        </article></body></html>
        """
        // The second hidden paragraph has a visible paragraph beside it, so it comes back; the short one doesn't.
        let body = try await extract(html)
        #expect(!body.contains("Advertisement"))
        #expect(body.contains("LONELY"))
    }

    @Test func aFullArticleBehindKiosqMarkupIsNotFlagged() async throws {
        let gate = "<div id=\"article-body\" class=\"text-copy bodyCopy auto paywall\"><div class=\"widget-area paywall-locker\"></div></div>"
        let page = Self.page(body: gate + String(repeating: p, count: 6))
        #expect(!PaywallDetection.isWalled(pageHTML: page, articleHTML: "<p>\(Self.words(500))</p>", url: "https://www.tomshardware.com/a"))
        // Cut after two paragraphs, the same page is walled.
        #expect(PaywallDetection.isWalled(pageHTML: page, articleHTML: "<p>\(Self.words(60))</p>", url: "https://www.tomshardware.com/a"))
    }

    @Test func theVideoCarouselBetweenParagraphsGoes() async throws {
        let carousel = """
        <div data-config="{}"><div data-jwp-carousel-header><span>Latest Videos From</span><span>Tom's Hardware</span></div>
        <div data-jwp-carousel-container><div data-jwp-carousel-player-host></div></div></div>
        """
        let body = try await extract("<html><head><title>T</title></head><body><article><h1>T</h1>\(p)\(carousel)\(p)</article></body></html>")
        #expect(!body.contains("Latest Videos"))
    }

    // MARK: Pages that say where the preview stops

    @Test func natureCutsAtItsPreviewLineAndWallsTheArticle() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>
        <h2>Abstract</h2><p>\(Self.para) ABSTRACT</p>
        <p>This is a preview of subscription content, <a href="/login">access via your institution</a></p>
        <h2>Access options</h2><p>Get Nature+ $39.99 / 30 days</p>
        <h2>Similar content being viewed by others</h2><p>Atom transfer radical polymerization</p>
        <h2>Author information</h2><p>Jun Huang, Yu Liu</p>
        </article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("ABSTRACT"))
        #expect(!body.contains("preview of subscription content"))
        #expect(!body.contains("Access options"))
        #expect(!body.contains("Similar content"))
        #expect(!body.contains("Author information"))
        // However much text the page chrome adds, the page's own words decide.
        #expect(PaywallDetection.isWalled(pageHTML: html, articleHTML: Self.words(900), url: "https://www.nature.com/articles/x"))
    }

    @Test func leMondeTeaserEndsAtItsLeftToReadLine() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>
        \(p)\(p)<p><strong>You have 86.43% of this article left to read. The rest is for subscribers only.</strong></p>
        </article></body></html>
        """
        let body = try await extract(html)
        #expect(!body.contains("left to read"))
        #expect(body.contains("The reader shows the whole story"))
        #expect(PaywallDetection.isWalled(pageHTML: html, articleHTML: Self.words(400), url: "https://www.lemonde.fr/en/a.html"))
        let french = "<p>Il vous reste 69,36 % de cet article à lire. La suite est réservée aux abonnés.</p>"
        #expect(PaywallDetection.isWalled(pageHTML: Self.page(body: french), articleHTML: Self.words(400), url: "https://www.lemonde.fr/a.html"))
    }

    @Test func aMarkerAloneIsNotCutWhenNothingIsAboveIt() async throws {
        let html = "<html><head><title>T</title></head><body><article><h1>T</h1><p>This is a preview of subscription content.</p></article></body></html>"
        let body = try await extract(html)
        #expect(body.contains("preview of subscription content"))
    }

    @Test func aMarkerInAScriptDoesNotWallThePage() {
        let page = Self.page(body: "<script>var t = 'You have {n}% of this article left to read';</script><p>Short but whole.</p>")
        #expect(!PaywallDetection.isWalled(pageHTML: page, articleHTML: Self.words(50), url: "https://e.com/a"))
    }

    // MARK: Server-cut pages (Japan Times)

    @Test func aPageWhoseOwnArticleBodyIsAFractionOfItsWordCountIsWalled() {
        let ld = Self.ld(#"{"@type":"NewsArticle","wordCount":"666","articleBody":"\#(Self.words(170))"}"#)
        let page = Self.page(head: ld, body: "<div class=\"subscribe\"><a href=\"/sub/?utm_campaign=sub\">SUBSCRIBE NOW</a></div>")
        #expect(PaywallDetection.isWalled(pageHTML: page, articleHTML: Self.words(175), url: "https://www.japantimes.co.jp/a"))
        // A site whose JSON-LD body is the whole story, cut or not by our extraction, says nothing about a wall.
        let whole = Self.ld(#"{"@type":"NewsArticle","wordCount":"666","articleBody":"\#(Self.words(660))"}"#)
        #expect(!PaywallDetection.isWalled(pageHTML: Self.page(head: whole), articleHTML: Self.words(175), url: "https://e.com/a"))
        // A short whole article is not cut.
        let brief = Self.ld(#"{"@type":"NewsArticle","wordCount":"107","articleBody":"\#(Self.words(100))"}"#)
        #expect(!PaywallDetection.isWalled(pageHTML: Self.page(head: brief), articleHTML: Self.words(105), url: "https://e.com/a"))
    }

    // MARK: Pages that call themselves free

    @Test func aFreeTierPageIsNotWalledByAModalsClassNamesOrAKnownSite() {
        let tier = "<meta property=\"article:content_tier\" content=\"free\"/>"
        let modal = "<aside class=\"PaywallModalWrapper paywall-modal\"></aside><div class=\"paywall-bar\"></div>"
        let page = Self.page(head: tier, body: modal + "<p>Already a subscriber? Sign in.</p>")
        #expect(!PaywallDetection.isWalled(pageHTML: page, articleHTML: Self.words(77), url: "https://www.newyorker.com/cartoons/daily-cartoon/x"))
        #expect(!PaywallDetection.isWalled(pageHTML: page, articleHTML: Self.words(200), url: "https://pitchfork.com/story/x"))
        // The same markup under a locked tier is still a wall.
        let locked = Self.page(head: tier.replacingOccurrences(of: "free", with: "locked"), body: modal)
        #expect(PaywallDetection.isWalled(pageHTML: locked, articleHTML: Self.words(77), url: "https://pitchfork.com/story/x"))
    }

    @Test func aTopLevelNotFreeThatListsOnlyAFreePartIsNotAWall() {
        // Politico: the article says false, its one hasPart says true, and the whole story is served.
        let politico = Self.ld(#"{"@type":"NewsArticle","hasPart":[{"@type":"WebPageElement","text":"The public block","isAccessibleForFree":true}],"isAccessibleForFree":false}"#)
        #expect(!PaywallDetection.isWalled(pageHTML: Self.page(head: politico), articleHTML: Self.words(112), url: "https://www.politico.com/news/a"))
        // Google's paywall markup: false on the article and on the part behind the wall.
        let google = Self.ld(#"{"@type":"NewsArticle","isAccessibleForFree":false,"hasPart":{"@type":"WebPageElement","isAccessibleForFree":false,"cssSelector":".paywall"}}"#)
        #expect(PaywallDetection.isWalled(pageHTML: Self.page(head: google), articleHTML: Self.words(112), url: "https://e.com/a"))
        // JSON-LD with raw line breaks inside a string is still read.
        let broken = Self.ld("{\"@type\":\"NewsArticle\",\"headline\":\"Two\nlines\",\"isAccessibleForFree\":false}")
        #expect(PaywallDetection.isWalled(pageHTML: Self.page(head: broken), articleHTML: Self.words(112), url: "https://e.com/a"))
    }

    // MARK: A wall that answers with an error (LWN)

    static let lwn = """
    <html><head><title>Subscription required [LWN.net]</title></head><body><div id="menu"><a href="/">LWN.net</a></div>
    <div class="PageHeadline"><h1>Subscription required</h1></div><div class="ArticleText"><main>
    The page you have tried to view  (<a href="/Articles/1/">Containers as a recognized kernel object</a>)  is currently available to LWN
    subscribers only. Reader subscriptions are a necessary way to fund the continued existence of LWN.
    <p>If you are already an LWN.net subscriber, please log in with the form below.<form><input name="uname"></form>
    </main></div></body></html>
    """

    @Test func aForbiddenPageThatSaysSubscribersOnlyIsAWalledArticle() async throws {
        PaywallStubProtocol.routes["https://lwn.net/Articles/1/"] = (403, Self.lwn)
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: PaywallStubProtocol.session())
        let out = try await ex.extractArticle(url: "https://lwn.net/Articles/1/", feed: nil)
        #expect(out.paywalled)
        let body = try #require(out.contentHtml)
        #expect(body.contains("is currently available to LWN subscribers only."))
        #expect(body.contains("Containers as a recognized kernel object"))
        #expect(!body.contains("uname"))
    }

    @Test func aBotCheckThatForbidsIsStillAnError() async throws {
        let check = "<html><body><p id=\"cmsg\">Please enable JS and disable any ad blocker</p></body></html>"
        PaywallStubProtocol.routes["https://e.com/dd"] = (403, check)
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: PaywallStubProtocol.session())
        await #expect(throws: HTTPError.status(403)) { try await ex.extractArticle(url: "https://e.com/dd", feed: nil) }
        #expect(PaywallDetection.wallResponse(check) == nil)
    }
}
