import Foundation
import Testing
@testable import OpenDispatchCore

/// URLProtocol stub: canned responses by URL, and a log of (url, User-Agent) for every request. No network.
final class ExtractionStubProtocol: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable { var status: Int; var headers: [String: String]; var body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Canned]] = [:]
    nonisolated(unsafe) private static var log: [(String, String)] = []

    /// Each URL serves its responses in order; the last one repeats.
    static func reset(_ r: [String: [Canned]]) { lock.lock(); routes = r; log = []; lock.unlock() }
    static func requests() -> [(String, String)] { lock.lock(); defer { lock.unlock() }; return log }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ExtractionStubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.log.append((url, request.value(forHTTPHeaderField: "User-Agent") ?? ""))
        var canned = Canned(status: 500, headers: [:], body: "")
        if var list = Self.routes[url], !list.isEmpty {
            canned = list[0]
            if list.count > 1 { list.removeFirst(); Self.routes[url] = list }
        }
        Self.lock.unlock()
        let res = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)
        if let res { client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// FeedParser stand-in: `itemHTML` returns a fixed string for any feed.
struct StubItemParser: FeedParser {
    var html: String?
    func parse(_ data: Data, kind: SourceKind, feedURL: String) throws -> ParsedFeed { ParsedFeed() }
    func itemHTML(in data: Data, guid: String, url: String) -> String? { html }
}

@Suite("Extraction: fetch flow (stubbed HTTP)", .serialized)
struct ExtractionFlowStubTests {
    static let para = String(repeating: "Stubbed article text that is long enough to be a real story body. ", count: 5)
    static let page = "<html><head><title>T</title><meta property=\"og:image\" content=\"/og.jpg\"></head><body><article><p>\(para)</p><p>\(para)</p></article></body></html>"
    static let html: [String: String] = ["Content-Type": "text/html; charset=utf-8"]

    @Test func retriesForbiddenAsBrowser() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/a": [.init(status: 403, headers: [:], body: ""), .init(status: 200, headers: Self.html, body: Self.page)],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        let out = try await ex.extractArticle(url: "https://e.com/a", feed: nil)
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
        #expect(out.leadImage == "https://e.com/og.jpg")
        #expect(out.rendered == false)
        let reqs = ExtractionStubProtocol.requests().filter { $0.0 == "https://e.com/a" }
        #expect(reqs.count == 2)
        #expect(reqs[0].1.contains("OpenDispatch/1.0"))
        #expect(reqs[1].1.contains("Chrome/"))
    }

    @Test func cloudflareChallengeIsNotRetried() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/cf": [.init(status: 403, headers: ["cf-mitigated": "challenge"], body: "")],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        await #expect(throws: HTTPError.status(403)) { try await ex.extractArticle(url: "https://e.com/cf", feed: nil) }
        #expect(ExtractionStubProtocol.requests().filter { $0.0 == "https://e.com/cf" }.count == 1)
        // The rendered fallback was tried (and failed: unstubbed URLs return 500).
        #expect(ExtractionStubProtocol.requests().contains { $0.0 == "https://r.jina.ai/https://e.com/cf" })
    }

    @Test func feedCopyWhenPageFails() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/b": [.init(status: 500, headers: [:], body: "")],
            "https://e.com/feed.xml": [.init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: "<rss/>")],
        ])
        let parser = StubItemParser(html: "<p>\(Self.para)</p><p>\(Self.para)</p><img src=\"/f.jpg\">")
        let ex = DefaultContentExtractor(parser: parser, readability: FakeReadability(), session: ExtractionStubProtocol.session())
        let out = try await ex.extractArticle(url: "https://e.com/b", feed: FeedRef(feedUrl: "https://e.com/feed.xml", guid: "g"))
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
        #expect(out.leadImage == "https://e.com/f.jpg")
        #expect(!ExtractionStubProtocol.requests().contains { $0.0.hasPrefix("https://r.jina.ai/") })
    }

    @Test func fullerFeedBeatsCutShortPage() async throws {
        let short = "<html><body><article><p>Only the first paragraph made it onto the page here.</p></article></body></html>"
        ExtractionStubProtocol.reset([
            "https://e.com/c": [.init(status: 200, headers: Self.html, body: short)],
            "https://e.com/feed2.xml": [.init(status: 200, headers: [:], body: "<rss/>")],
        ])
        let full = (0..<4).map { _ in "<p>\(Self.para)</p>" }.joined()
        let ex = DefaultContentExtractor(parser: StubItemParser(html: full), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        let out = try await ex.extractArticle(url: "https://e.com/c", feed: FeedRef(feedUrl: "https://e.com/feed2.xml", guid: "g"))
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
    }

    @Test func renderedFallbackMarksRendered() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/js": [.init(status: 200, headers: Self.html, body: "<html><body><div id=app></div></body></html>")],
            "https://r.jina.ai/https://e.com/js": [.init(status: 200, headers: Self.html, body: Self.page)],
        ])
        let empty = FakeEmptyReadabilityOnce()
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: empty, session: ExtractionStubProtocol.session())
        let out = try await ex.extractArticle(url: "https://e.com/js", feed: nil)
        #expect(out.rendered)
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
    }

    @Test func unsupportedContentType() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/file.pdf": [.init(status: 200, headers: ["Content-Type": "application/pdf"], body: "%PDF")],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        await #expect(throws: ExtractionError.unsupportedContentType("application/pdf")) {
            try await ex.extractArticle(url: "https://e.com/file.pdf", feed: nil)
        }
    }

    @Test func podcastNotesFromFeed() async throws {
        ExtractionStubProtocol.reset([
            "https://e.com/pod.xml": [.init(status: 200, headers: [:], body: "<rss/>")],
            "https://e.com/bad.xml": [.init(status: 404, headers: [:], body: "")],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(html: "Episode notes\n\nSecond"), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        let out = try await ex.extractPodcastNotes(url: "https://e.com/ep1", feed: FeedRef(feedUrl: "https://e.com/pod.xml", guid: "g"))
        #expect(out.contentHtml == "<p>Episode notes</p><p>Second</p>")
        await #expect(throws: ExtractionError.feedStatus(404)) {
            try await ex.extractPodcastNotes(url: "https://e.com/ep1", feed: FeedRef(feedUrl: "https://e.com/bad.xml", guid: "g"))
        }
    }

    @Test func contentServiceCachesExtraction() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, url: "https://e.com", feedUrl: "https://e.com/feed3.xml")
        let up = try Fixture.items(db, sourceId: src.id, [ParsedItem(guid: "g", url: "https://e.com/d", title: "D", publishedAt: Fixture.base)])
        ExtractionStubProtocol.reset([
            "https://e.com/d": [.init(status: 200, headers: Self.html, body: Self.page)],
        ])
        let ex = DefaultContentExtractor(parser: StubItemParser(), readability: FakeReadability(), session: ExtractionStubProtocol.session())
        let service = ContentService(database: db, extractor: ex)
        let id = try #require(up.first?.id)
        let out = try await service.content(forItem: id)
        #expect(out.contentHtml?.contains("Stubbed article text") == true)
        let stored = try await db.itemRecord(id: id)
        #expect(stored?.contentHtml == out.contentHtml)
        #expect(stored?.contentRendered == false)
    }
}

/// Finds nothing on the first call (a JavaScript-only page), then behaves like FakeReadability.
final class FakeEmptyReadabilityOnce: ReadabilityEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private func takeFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isFirst = first
        first = false
        return isFirst
    }

    func articleContent(html: String, baseURL: String) async throws -> String? {
        if takeFirst() { return nil }
        return try await FakeReadability().articleContent(html: html, baseURL: baseURL)
    }
}
