import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Canned responses by URL (this suite's own copy of ExtractionStubProtocol, so the suites can run side by side).
final class ContentLossStub: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable { var status: Int; var headers: [String: String]; var body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Canned] = [:]
    nonisolated(unsafe) private static var log: [String] = []

    static func reset(_ r: [String: [Canned]]) { lock.lock(); routes = r.compactMapValues(\.first); log = []; lock.unlock() }
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ContentLossStub.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.log.append(url)
        let canned = Self.routes[url] ?? Canned(status: 500, headers: [:], body: "")
        Self.lock.unlock()
        if let res = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers) {
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Article text that went missing on news sites (BBC, MLB, CNBC, Apple, Politico, Smithsonian, TV Insider, Times of India,
/// ProPublica, LA Times): the passes in ArticlePasses+ContentLoss.
@Suite("Extraction: content loss")
struct ExtractionContentLossTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    /// The root's inner HTML after `pass`.
    func run(_ html: String, _ pass: (Element) -> Void) throws -> String {
        try #require(ExtractionDOM.withFragment("<div id=\"__root\">\(html)</div>") { body -> String in
            guard let root = ExtractionDOM.first(body, "#__root") else { return "" }
            pass(root)
            return ExtractionDOM.innerHTML(root)
        })
    }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    // MARK: Author links in prose

    @Test func aSentenceThatLinksAPersonStays() {
        let out = ArticlePasses.cleanArticle("""
        <p>In the spring of 1726, a mysterious cloaked figure visited a London bookseller named <a href="https://e.com/people/669/">Benjamin Motte</a> with a manuscript in hand.</p>
        <p>Yes, Barnes appeared on <a href="https://e.com/people/candace-cameron-bure/">Candace Cameron Bure</a>'s podcast in October and revealed he and his wife separated in January because of his infidelity.</p>
        <div><a href="https://e.com/author/jane-doe">Jane Doe</a> Senior Reporter</div>
        <p>By <a href="https://e.com/author/jane-doe">Jane Doe</a>, October 29, 2026.</p>
        \(p)
        """, base: nil)
        #expect(out.contains("named"))
        #expect(out.contains("Motte"))
        #expect(out.contains("Candace Cameron Bure"))
        #expect(!out.contains("Senior Reporter"))
        #expect(!out.contains("October 29"))
    }

    // MARK: Component columns

    @Test func componentColumnsLoseTheirWrappers() throws {
        func block(_ text: String) -> String {
            "<div class=\"wrap\"><div class=\"spacer\"><div class=\"rich\"><p>\(text)</p></div></div></div>"
        }
        let long = "Seven months after becoming champions with Team Venezuela, three players pulled off a rare double."
        let out = try run("""
        <div class="column"><div class="head"><img src="https://e.com/a.jpg"></div>
        \(block("ST. PETERSBURG -- In March, <a href=\"/a\">they celebrated</a> in Florida with beer and champagne."))
        \(block(long)) \(block("Now, they have company, and a long story to tell about the whole thing."))
        <div class="ad"><p>Advertisement</p></div></div>
        """, ArticlePasses.flattenComponentColumns)
        #expect(!out.contains("wrap"))
        #expect(!out.contains("spacer"))
        let paragraphs = try #require(ExtractionDOM.withFragment(out) { body in
            ExtractionDOM.select(body, "p").filter { $0.parent().map { ExtractionDOM.classTokens($0) == ["column"] } ?? false }.count
        })
        #expect(paragraphs == 3)
    }

    @Test func twoComponentsAreNotAColumn() throws {
        let html = "<div class=\"col\"><div class=\"w\"><p>\(Self.para)</p></div><div class=\"w\"><p>\(Self.para)</p></div></div>"
        #expect(try run(html, ArticlePasses.flattenComponentColumns).components(separatedBy: "class=\"w\"").count == 3)
    }

    @Test func aRelatedBoxIsNotUnwrappedIntoTheColumn() throws {
        func block(_ cls: String) -> String { "<div class=\"\(cls)\"><div><p>\(Self.para)</p></div></div>" }
        let out = try run(block("related-links") + block("related-links") + block("related-links"), ArticlePasses.flattenComponentColumns)
        #expect(out.contains("related-links"))
    }

    @Test func bareTextDivsBecomeParagraphs() throws {
        let out = try run("""
        <div class="copy">M6 brings even more performance and next-level AI capabilities to the 14-inch MacBook Pro.</div>
        <div class="copy">Short.</div>
        <div class="copy">Read the <a href="/a">full spec sheet</a> and <a href="/b">the pricing page</a> for more.</div>
        <div><p>Inside</p>\(p)</div>
        """, ArticlePasses.bareTextDivsToParagraphs)
        #expect(out.contains("<p class=\"copy\">M6 brings"))
        #expect(out.contains("<div class=\"copy\">Short.</div>"))
        #expect(out.contains("<div class=\"copy\">Read the"))
    }

    @Test func aBylineBlockNamedByDataAttributesGoes() throws {
        let out = try run("""
        <div data-block="byline"><span>Richard Wheeler</span></div><div data-block="metadata"><time>3 hours ago</time></div>
        <div data-testid="single-byline">Reporter</div><div data-block="text">\(p)</div>
        """, ArticlePasses.dropComponentMeta)
        #expect(!out.contains("Wheeler"))
        #expect(!out.contains("hours ago"))
        #expect(!out.contains("Reporter"))
        #expect(out.contains("The reader shows"))
    }

    // MARK: Paragraph breaks

    @Test func emptyBreakSpansSplitTextIntoParagraphs() async throws {
        let html = """
        <html><head><title>Israel</title></head><body><article><h1>Israel</h1>
        <div class="body">The counting of votes has confirmed Likud as the largest party.<span class="id-r-component br" data-pos="2"></span>According to official figures, the bloc secured 53 seats.<span class="id-r-component br"></span>The final tally, which included <a href="/x">ballots</a>, confirmed it.<div class="ad"><p>Ad</p></div></div></article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("<p>The counting of votes has confirmed Likud as the largest party.</p>"))
        #expect(body.contains("<p>According to official figures, the bloc secured 53 seats.</p>"))
        #expect(body.contains("<p>The final tally, which included"))
        #expect(!body.contains("largest party.According"))
    }

    // MARK: Key points

    @Test func keyPointsMoveIntoTheBody() throws {
        let out = try run("""
        <div data-element="story-summary"><ul><li>Trump is rallying in five states where the party worries its own voters may stay home.</li></ul></div>
        <div data-element="story-body"><div class="ad"></div>\(p)\(p)</div>
        """, ArticlePasses.summaryIntoBody)
        let order = try #require(ExtractionDOM.withFragment(out) { body in
            ExtractionDOM.select(body, "[data-element=story-body] > *").map { ExtractionDOM.tag($0) }
        })
        #expect(order == ["div", "div", "p", "p"])
        #expect(out.contains("Trump is rallying"))
        #expect(out.range(of: "story-summary")!.lowerBound > out.range(of: "story-body")!.lowerBound)
    }

    @Test func aSummaryWithNoBodyBesideItStays() throws {
        let html = "<div class=\"RenderKeyPoints-keyPoints\"><ul><li>One point that is long enough to be a point.</li></ul></div><div>Short</div>"
        let out = try run(html, ArticlePasses.summaryIntoBody)
        #expect(out.range(of: "RenderKeyPoints")!.lowerBound < out.range(of: "Short")!.lowerBound)
    }

    // MARK: Politico

    static let stubHTML: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
    static func politicoPage(private privateHTML: String) -> String {
        "<html><head><title>T</title><script type=\"application/ld+json\">{\"isAccessibleForFree\":false}</script></head><body><article>"
            + "<div class=\"public-article-content\" data-public-article-content=\"\"><p>\(para)</p></div>"
            + "<div class=\"private-article-content\" data-private-article-content>\(privateHTML)</div></article></body></html>"
    }

    @Test func anEmptyPrivateHalfIsRecognised() {
        #expect(ArticlePasses.hasUnfilledPrivateContent(Self.politicoPage(private: "<!--[--><!--]-->")))
        #expect(ArticlePasses.hasUnfilledPrivateContent(Self.politicoPage(private: "")))
        #expect(!ArticlePasses.hasUnfilledPrivateContent(Self.politicoPage(private: "<p>The rest of the story.</p>")))
        #expect(!ArticlePasses.hasUnfilledPrivateContent("<div class=\"private\"></div>"))
    }

    @Test func aStoryTheScriptsFinishIsTakenFromTheRenderedCopy() async throws {
        // Distinct paragraphs: the same one in two boxes near the top reads as a teaser and its copy.
        let full = Self.politicoPage(private: "<p>\(Self.para) Two.</p><p>\(Self.para) Three.</p><p>\(Self.para) Four.</p>").replacingOccurrences(of: "\"isAccessibleForFree\":false", with: "\"isAccessibleForFree\":true")
        ContentLossStub.reset([
            "https://e.com/p": [.init(status: 200, headers: Self.stubHTML, body: Self.politicoPage(private: "<!--[--><!--]-->"))],
            "https://r.jina.ai/https://e.com/p": [.init(status: 200, headers: Self.stubHTML, body: full)],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ContentLossStub.session())
        let out = try await ex.extractArticle(url: "https://e.com/p", feed: nil)
        #expect(out.rendered)
        #expect(!out.paywalled)
        #expect(out.contentHtml?.components(separatedBy: "The reader shows").count == 17)

        // A page that carries its whole story is read as it is.
        ContentLossStub.reset([
            "https://e.com/q": [.init(status: 200, headers: Self.stubHTML, body: Self.politicoPage(private: "<p>\(Self.para)</p>"))],
        ])
        let whole = try await ex.extractArticle(url: "https://e.com/q", feed: nil)
        #expect(!whole.rendered)
        #expect(!ContentLossStub.requests().contains { $0.hasPrefix("https://r.jina.ai/") })

        // Still empty when rendered (Politico stopped filling it for Jina): the public half, a preview.
        let teaser = Self.politicoPage(private: "<!--[--><!--]-->")
        ContentLossStub.reset([
            "https://e.com/r": [.init(status: 200, headers: Self.stubHTML, body: teaser)],
            "https://r.jina.ai/https://e.com/r": [.init(status: 200, headers: Self.stubHTML, body: teaser)],
        ])
        let preview = try await ex.extractArticle(url: "https://e.com/r", feed: nil)
        #expect(!preview.rendered && preview.paywalled)
    }

    // MARK: ProPublica

    @Test func aFilterableDatabaseGoesAndTheTextAroundItJoins() throws {
        let cards = (0..<25).map { "<div class=\"card\"><span>Oct. \($0)</span><div>A citizen was detained and then released after a long delay by agents.</div></div>" }.joined()
        let out = try run("""
        <div><div class="intro">\(p)</div><div id="incident-table"><div class="incident-table">
        <select aria-label="Filter by type"><option>All</option></select><select aria-label="Sort by date"><option>New</option></select>
        <div class="incident-list">\(cards)</div></div></div></div>
        <div class="credits-footer"><div class="credits"><h2>How We Reported This Story</h2><div class="content"><h3>How We Counted</h3>\(p)\(p)\(p)</div></div></div>
        """, ArticlePasses.dropDatabaseWidget)
        #expect(!out.contains("incident-list"))
        #expect(!out.contains("A citizen was detained"))
        #expect(!out.contains("footer"))
        let pos = ["The reader shows", "How We Reported This Story", "How We Counted"].map { out.range(of: $0)?.lowerBound }
        #expect(!pos.contains { $0 == nil })
        #expect(out.components(separatedBy: "<p>").count == 5)
    }

    @Test func aPageWithOneSelectIsLeftAlone() throws {
        let html = "<select aria-label=\"Language\"><option>EN</option></select>\(p)"
        #expect(try run(html, ArticlePasses.dropDatabaseWidget).contains("The reader shows"))
    }

    // MARK: Newsletter prompt

    @Test func aNewsletterPromptLineGoes() throws {
        let out = try run("""
        <p>GET THIS IN YOUR INBOX FIRST: Subscribe to CNBC's "Power Insider" newsletter.</p>\(p)
        <p>Subscribe to our newsletter for the best reporting, and read how the board decided to spend the money.</p>
        """, ArticlePasses.dropNewsletterPrompts)
        #expect(!out.contains("INBOX FIRST"))
        #expect(out.contains("The reader shows"))
    }

    // MARK: Whole pipeline

    @Test func columnOfComponentsKeepsEveryParagraphThroughExtraction() async throws {
        func block(_ text: String) -> String { "<div class=\"w\"><div class=\"s\"><div class=\"r\"><p>\(text)</p></div></div></div>" }
        let html = """
        <html><head><title>Story</title></head><body><article><h1>Story</h1>
        \(block("Dateline first graf with a <a href=\"/a\">link</a> in it. It is long enough to read as a paragraph of the story."))
        \(block(Self.para)) \(block(Self.para))
        </article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Dateline first graf"))
        #expect(body.components(separatedBy: "The reader shows").count == 9)
    }
}
