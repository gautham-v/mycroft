import Foundation
import Synchronization
import Testing
@testable import OpenDispatchCore

/// Answers requests from a handler and records what was sent. Only IntegrationTests uses it, and that
/// suite is serialized, so a single static handler is safe.
final class IntegrationMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (Int, Data)
    struct Recorded: Sendable { let request: URLRequest; let body: Data? }

    static let handler = Mutex<Handler?>(nil)
    static let recorded = Mutex<[Recorded]>([])

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [IntegrationMockURLProtocol.self]
        return URLSession(configuration: c)
    }

    static func reset(_ h: @escaping Handler) {
        handler.withLock { $0 = h }
        recorded.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        Self.recorded.withLock { $0.append(Recorded(request: request, body: body)) }
        guard let h = Self.handler.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try h(request, body)
            let res = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
            if let res { client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ s: InputStream) -> Data {
        s.open()
        defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }
}

@Suite("Integrations", .serialized)
struct IntegrationTests {
    static let published = Date(timeIntervalSince1970: 1_790_000_000)

    func feedItem(author: String? = "Ada", summary: String? = "<p>Hello &amp; <b>world</b></p>") -> FeedItem {
        let source = Source(id: 3, title: "Example Blog", url: "https://www.example.com/blog", feedUrl: "https://www.example.com/feed", kind: .rss, group: "blogs")
        let item = Item(id: 42, sourceId: 3, guid: "g1", url: "https://example.com/post", title: "A post", summary: summary,
                        author: author, publishedAt: Self.published)
        return FeedItem(item: item, source: source)
    }

    func service(token: String? = nil, webhook: String? = nil) async throws -> DefaultIntegrationService {
        let db = try Fixture.db()
        if let webhook { try await db.setMeta(MetaKey.webhookURL, webhook) }
        return DefaultIntegrationService(database: db, tokenStore: InMemoryReadwiseTokenStore(token), session: IntegrationMockURLProtocol.session())
    }

    func json(_ data: Data?) throws -> [String: Any] {
        let d = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func sendError(_ op: () async throws -> Void) async -> IntegrationError? {
        do {
            try await op()
            return nil
        } catch {
            return error as? IntegrationError
        }
    }

    // MARK: Payload

    @Test func webhookPayloadFromItem() throws {
        let p = WebhookPayload(item: feedItem(author: nil))
        #expect(p.id == 42)
        #expect(p.summary == "Hello & world")
        #expect(p.source == .init(title: "Example Blog", host: "example.com"))
        #expect(p.test == nil)

        let o = try json(try p.webhookJSON())
        #expect(Set(o.keys) == ["id", "url", "title", "author", "published_at", "summary", "source"])
        #expect(o["author"] is NSNull)
        #expect(o["published_at"] as? String == ISO8601.string(from: Self.published))
        #expect(o["url"] as? String == "https://example.com/post")
        #expect((o["source"] as? [String: String]) == ["title": "Example Blog", "host": "example.com"])
        // Slashes are not escaped.
        #expect(String(decoding: try p.webhookJSON(), as: UTF8.self).contains("https://example.com/post"))

        let empty = WebhookPayload(item: feedItem(summary: "  <br> "))
        #expect(try json(try empty.webhookJSON())["summary"] is NSNull)
    }

    @Test func testPayload() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let o = try json(try WebhookPayload.test(now: now).webhookJSON())
        #expect(o["id"] as? Int == 0)
        #expect(o["test"] as? Bool == true)
        #expect(o["title"] as? String == "Test from OpenDispatch")
        #expect(o["published_at"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(o["summary"] as? String == "A sample payload sent from Settings \u{2192} Integrations.")
    }

    @Test func readwiseBody() throws {
        let long = String(repeating: "word ", count: 400)
        var o = try json(try IntegrationRequests.readwiseBody(feedItem(summary: long)))
        #expect(o["saved_using"] as? String == "opendispatch")
        #expect(o["author"] as? String == "Ada")
        #expect((o["summary"] as? String)?.count == 1000)
        #expect(o["published_date"] as? String == ISO8601.string(from: Self.published))
        o = try json(try IntegrationRequests.readwiseBody(feedItem(author: nil, summary: nil)))
        #expect(o["author"] == nil)
        #expect(o["summary"] == nil)
    }

    // MARK: Configuration

    @Test func webhookURLValidation() async throws {
        let s = try await service()
        #expect(IntegrationRequests.parseWebhookURL(" https://Hooks.Example.com ") == "https://hooks.example.com/")
        #expect(IntegrationRequests.parseWebhookURL("http://x.test:8080/a?b=1") == "http://x.test:8080/a?b=1")
        #expect(IntegrationRequests.parseWebhookURL("ftp://x.test") == nil)
        #expect(IntegrationRequests.parseWebhookURL("not a url") == nil)

        let err = await sendError { try await s.setWebhookURL("ftp://x.test") }
        #expect(err == .invalidWebhookURL)
        #expect(err?.localizedDescription == "Webhook URL must start with http:// or https://")

        var st = try await s.setWebhookURL("https://hooks.example.com/in")
        #expect(st.webhookURL == "https://hooks.example.com/in")
        #expect(st.configuredTargets == [.webhook])
        st = try await s.setWebhookURL("  ")
        #expect(st.webhookURL == nil)
        #expect(!st.webhookConfigured)
    }

    @Test func readwiseTokenHint() async throws {
        let s = try await service()
        var st = try await s.setReadwiseToken("  secret-token-abcd ")
        #expect(st.readwiseConfigured)
        #expect(st.readwiseTokenHint == "\u{2026}abcd")
        st = try await s.setReadwiseToken(nil)
        #expect(!st.readwiseConfigured)
        #expect(st.readwiseTokenHint == nil)
    }

    @Test func legacyTokenMovesOutOfMeta() async throws {
        let db = try Fixture.db()
        try await db.setMeta(MetaKey.readwiseToken, "legacy1234")
        let store = InMemoryReadwiseTokenStore()
        let s = DefaultIntegrationService(database: db, tokenStore: store, session: IntegrationMockURLProtocol.session())
        let st = try await s.state()
        #expect(st.readwiseTokenHint == "\u{2026}1234")
        #expect(try store.readToken() == "legacy1234")
        #expect(try await db.meta(MetaKey.readwiseToken) == nil)
    }

    @Test func notConfigured() async throws {
        let s = try await service()
        let e1 = await sendError { try await s.send(feedItem(), to: .readwise) }
        #expect(e1?.localizedDescription == "Readwise is not set up")
        let e2 = await sendError { try await s.test(.webhook) }
        #expect(e2?.localizedDescription == "Webhook is not set up")
    }

    // MARK: Sending (URLProtocol-mocked)

    @Test func sendToWebhook() async throws {
        IntegrationMockURLProtocol.reset { _, _ in (204, Data()) }
        let s = try await service(webhook: "https://hooks.example.com/in")
        try await s.send(feedItem(), to: .webhook)
        let r = try #require(IntegrationMockURLProtocol.recorded.withLock { $0 }.first)
        #expect(r.request.url?.absoluteString == "https://hooks.example.com/in")
        #expect(r.request.httpMethod == "POST")
        #expect(r.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.request.value(forHTTPHeaderField: "User-Agent") == HTTP.userAgent)
        let o = try json(r.body)
        #expect(o["id"] as? Int == 42)
        #expect(o["title"] as? String == "A post")
        #expect(o["test"] == nil)
    }

    @Test func webhookTestSendsSample() async throws {
        IntegrationMockURLProtocol.reset { _, _ in (200, Data("ok".utf8)) }
        let s = try await service(webhook: "https://hooks.example.com/in")
        try await s.test(.webhook)
        let r = try #require(IntegrationMockURLProtocol.recorded.withLock { $0 }.first)
        #expect(try json(r.body)["test"] as? Bool == true)
    }

    @Test func webhookErrors() async throws {
        let s = try await service(webhook: "https://hooks.example.com/in")

        IntegrationMockURLProtocol.reset { _, _ in (500, Data(#"{"detail":"boom"}"#.utf8)) }
        var e = await sendError { try await s.send(feedItem(), to: .webhook) }
        #expect(e == .send(message: "Webhook returned 500: boom", status: 502))

        IntegrationMockURLProtocol.reset { _, _ in (404, Data("<html><body>Not found</body></html>".utf8)) }
        e = await sendError { try await s.send(feedItem(), to: .webhook) }
        #expect(e?.localizedDescription == "Webhook returned 404")

        IntegrationMockURLProtocol.reset { _, _ in (422, Data("bad payload".utf8)) }
        e = await sendError { try await s.send(feedItem(), to: .webhook) }
        #expect(e?.localizedDescription == "Webhook returned 422: bad payload")

        IntegrationMockURLProtocol.reset { _, _ in throw URLError(.timedOut) }
        e = await sendError { try await s.send(feedItem(), to: .webhook) }
        #expect(e == .send(message: "Webhook: Timed out", status: 504))

        IntegrationMockURLProtocol.reset { _, _ in throw URLError(.cannotFindHost) }
        e = await sendError { try await s.send(feedItem(), to: .webhook) }
        #expect(e?.status == 502)
        #expect(e?.localizedDescription.hasPrefix("Webhook: ") == true)
    }

    @Test func sendToReadwise() async throws {
        let s = try await service(token: "tok123")
        IntegrationMockURLProtocol.reset { _, _ in (201, Data("{}".utf8)) }
        try await s.send(feedItem(), to: .readwise)
        let r = try #require(IntegrationMockURLProtocol.recorded.withLock { $0 }.first)
        #expect(r.request.url?.absoluteString == "https://readwise.io/api/v3/save/")
        #expect(r.request.httpMethod == "POST")
        #expect(r.request.value(forHTTPHeaderField: "Authorization") == "Token tok123")
        let o = try json(r.body)
        #expect(o["url"] as? String == "https://example.com/post")
        #expect(o["summary"] as? String == "Hello & world")

        // 200 = already in the library.
        IntegrationMockURLProtocol.reset { _, _ in (200, Data("{}".utf8)) }
        try await s.send(feedItem(), to: .readwise)

        // Field errors are flattened.
        IntegrationMockURLProtocol.reset { _, _ in (400, Data(#"{"url":["Enter a valid URL."],"title":["Too long","Bad"]}"#.utf8)) }
        let e = await sendError { try await s.send(feedItem(), to: .readwise) }
        #expect(e?.localizedDescription == "Readwise returned 400: title: Too long Bad; url: Enter a valid URL.")
    }

    @Test func readwiseVerify() async throws {
        let s = try await service(token: "tok123")
        IntegrationMockURLProtocol.reset { _, _ in (204, Data()) }
        try await s.test(.readwise)
        let r = try #require(IntegrationMockURLProtocol.recorded.withLock { $0 }.first)
        #expect(r.request.url?.absoluteString == "https://readwise.io/api/v2/auth/")
        #expect(r.request.httpMethod == "GET")
        #expect(r.request.value(forHTTPHeaderField: "Authorization") == "Token tok123")

        IntegrationMockURLProtocol.reset { _, _ in (401, Data(#"{"detail":"Invalid token."}"#.utf8)) }
        var e = await sendError { try await s.test(.readwise) }
        #expect(e?.localizedDescription == "Readwise rejected the token")

        IntegrationMockURLProtocol.reset { _, _ in (503, Data(#"{"error":"down"}"#.utf8)) }
        e = await sendError { try await s.test(.readwise) }
        #expect(e?.localizedDescription == "Readwise returned 503: down")
    }

    /// Touches the real login/data-protection Keychain, so it only runs with OPENDISPATCH_KEYCHAIN_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeychainReadwiseTokenStore(service: "com.gauthamv.opendispatch.tests", account: "readwise_token_\(UUID().uuidString)")
        defer { try? store.writeToken(nil) }
        #expect(try store.readToken() == nil)
        try store.writeToken("first")
        try store.writeToken("second")
        #expect(try store.readToken() == "second")
        try store.writeToken(nil)
        #expect(try store.readToken() == nil)
        try store.writeToken(nil)
    }
}
