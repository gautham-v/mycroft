import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Bot checks served as the page (The Sun), notices and widgets that are no part of the story (NHK's licensing dialog,
/// SCMP's text-to-speech player, Nature's jobs board), a framework's error text (Politico) and a poster-only video.
/// Canned responses by URL (this suite's own copy of ExtractionStubProtocol, so the suites can run side by side).
final class WallsStub: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable { var status: Int; var headers: [String: String]; var body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Canned] = [:]
    nonisolated(unsafe) private static var log: [String] = []

    static func reset(_ r: [String: [Canned]]) { lock.lock(); routes = r.compactMapValues(\.first); log = []; lock.unlock() }
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [WallsStub.self]
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

@Suite("Extraction: walls and notices", .serialized)
struct ExtractionWallsTests {
    typealias DOM = ExtractionDOM

    func parse(_ html: String, url: String = "https://e.com/story") throws -> Document {
        try #require(DOM.parseDocument(html, baseURI: url))
    }

    // MARK: Bot checks

    @Test func aShortBotCheckPageIsABotCheck() {
        #expect(ArticleExtraction.isBotCheck("<div><p>Verifying your device, please wait</p><p>Verification failed. Please try again.</p></div>"))
        #expect(ArticleExtraction.isBotCheck("<h1>Just a moment...</h1><p>Enable JavaScript and cookies to continue</p>"))
        #expect(!ArticleExtraction.isBotCheck("<p>\(String(repeating: "A long story that mentions verification failed once. ", count: 20))</p>"))
        #expect(!ArticleExtraction.isBotCheck("<p>Short but a real note about the weather.</p>"))
    }

    @Test func aBotCheckServedWithStatus200FailsInsteadOfBeingTheArticle() async throws {
        let page = "<html><head><title>Verifying Device</title></head><body><article><p>Verifying your device, please wait</p><p>Verification failed. Please try again.</p></article></body></html>"
        WallsStub.reset(["https://e.com/bot": [.init(status: 200, headers: ["Content-Type": "text/html"], body: page)]])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: WallsStub.session())
        await #expect(throws: ExtractionError.botCheck) {
            try await ex.extractArticle(url: "https://e.com/bot", feed: nil)
        }
    }

    // MARK: Dialogs

    static let lede = "A very strong typhoon is moving over the sea west of the main island and the warning stays in force for hours."

    @Test func aModalDialogIsNotTheStory() throws {
        let doc = try parse("""
        <html><body><dialog open><p>The service is free for everyone. Households with a reception contract pay nothing extra.</p></dialog>
        <main><h1>Typhoon</h1><p>\(Self.lede)</p></main></body></html>
        """)
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.first(doc, "dialog") == nil)
        #expect(DOM.text(doc).contains("typhoon"))
    }

    @Test func aDialogHoldingTheStoryStays() throws {
        let doc = try parse("<html><body><dialog open><h1>Story</h1><p>\(String(repeating: "Whole story. ", count: 3))</p></dialog></body></html>")
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.first(doc, "dialog") != nil)
    }

    @Test func nhkKeepsTheHeadlinePictureAndLedeNotTheMenuOrCards() throws {
        let doc = try parse("""
        <html><body><header><a href="/"><svg></svg></a></header><main><div><img src="https://i.e.com/hero.jpg"><h1>Typhoon 13</h1>
        <div><time>2026</time></div><div><p>\(Self.lede)</p><p>NHK ONE ニュース・防災アプリ</p><p>N…</p></div>
        <div><h2>More</h2><ul><li><a href="/x"><p>Another headline entirely</p></a></li></ul></div></div></main></body></html>
        """, url: "https://news.web.nhk/newsweb/na/na-k1")
        ArticlePasses.removeNotices(doc, pageURL: "https://news.web.nhk/newsweb/na/na-k1")
        let text = DOM.text(doc)
        #expect(text.contains("typhoon"))
        #expect(!text.contains("ニュース・防災アプリ"))
        #expect(!text.contains("N…"))
        #expect(!text.contains("Another headline"))
        #expect(DOM.first(doc, "img[src$=hero.jpg]") != nil)
    }

    @Test func otherSitesAreNotRewrittenLikeNHK() throws {
        let doc = try parse("<html><body><main><h1>T</h1><p>\(Self.lede)</p><ul><li><a href='/x'><p>Related story</p></a></li></ul></main></body></html>")
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.text(doc).contains("Related story"))
    }

    // MARK: Widgets

    @Test func widgetsNamedByTestAttributeGo() throws {
        let doc = try parse("""
        <html><body><div data-qa="ArticleReadingTime-Container"><span>5-MIN READ</span></div>
        <div data-qa="ArticleSpeechInlineWidgetArticle20-Container"><span>Listen</span></div>
        <div data-qa="TextToSpeechPlayer-Container"><p>Select Voice</p><p>Select Speed</p><p>AI-generated voice</p></div>
        <article><p>\(Self.lede)</p></article></body></html>
        """)
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        let text = DOM.text(doc)
        #expect(text.contains("typhoon"))
        for gone in ["5-MIN READ", "Listen", "Select Voice", "AI-generated voice"] { #expect(!text.contains(gone)) }
    }

    @Test func aStoryInsideAMatchingWrapperStays() throws {
        let long = String(repeating: "The whole story sits in a wrapper that happens to be named like a widget. ", count: 40)
        let doc = try parse("<html><body><div data-qa='TextToSpeech-Article'><p>\(long)</p></div></body></html>")
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.text(doc).contains("The whole story"))
    }

    @Test func aJobsBoardGoes() throws {
        let doc = try parse("""
        <html><body><article><p>\(Self.lede)</p></article><div class="js-jobs-career-wrapper"><h2><img src="/careers-logo.svg" alt="Careers"></h2><h3><a href="/careers">Jobs</a></h3>
        <ul><li><h4><a href="/job/1">Head of a department</a></h4></li></ul></div></body></html>
        """)
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.text(doc).contains("typhoon"))
        #expect(!DOM.text(doc).contains("Jobs"))
        #expect(DOM.first(doc, "img") == nil)
    }

    // MARK: Render errors

    @Test func aFrameworkErrorInThePageTextGoes() throws {
        let doc = try parse("""
        <html><body><article><p>\(Self.lede)</p><div style="display: none;">[@portabletext/vue] Unknown block type "most-read", specify a component for it in the `components.types` prop</div></article></body></html>
        """)
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.text(doc).contains("typhoon"))
        #expect(!DOM.text(doc).contains("portabletext"))
    }

    @Test func aStoryThatQuotesAnErrorStays() throws {
        let doc = try parse("<html><body><article><p>The log said [@portabletext/vue] was missing a component, the engineer wrote.</p></article></body></html>")
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.text(doc).contains("engineer"))
    }

    // MARK: Poster-only videos

    @Test func aPosterOnlyVideoLinksToItsPage() throws {
        let doc = try parse("""
        <html><body><article><h2>Watch: The Conversation</h2><div><div><div><aside data-testid="site-video-640"><figure><div><button aria-label="Play video">
        <img class="video-poster" src="https://e.com/dims4/default/resize/270/quality/90/format/webp?url=poster.jpg"></button></div></figure></aside></div>
        <div><a href="https://e.com/video/2026/10/22/clip-1">Can she prove it?</a></div></div></div></article></body></html>
        """)
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        let img = try #require(DOM.first(doc, "figure a[href$=clip-1] img"))
        #expect(DOM.attr(img, "src")?.contains("/resize/1200/") == true)
        #expect(DOM.first(doc, "figcaption").map { DOM.text($0).contains("Can she prove it?") } == true)
        #expect(DOM.first(doc, "aside") == nil)
    }

    @Test func aPlayableVideoCardIsLeftAlone() throws {
        let doc = try parse("<html><body><article><aside data-testid='site-video-1'><video src='https://e.com/v.mp4'></video></aside><a href='https://e.com/video/1'>Clip</a></article></body></html>")
        ArticlePasses.removeNotices(doc, pageURL: "https://e.com/story")
        #expect(DOM.first(doc, "video") != nil)
    }
}
