import Foundation
import Testing
@testable import OpenDispatchCore

/// Part of the serialized IntegrationTests suite: these share its static URLProtocol handler.
extension IntegrationTests {
    func sender(_ db: AppDatabase, token: String? = "tok") -> ReadwiseHighlightSync {
        ReadwiseHighlightSync(database: db, tokenStore: InMemoryReadwiseTokenStore(token), session: IntegrationMockURLProtocol.session())
    }

    static func response(_ ids: [Int]) -> Data {
        Data(#"[{"id":1,"title":"T","modified_highlights":\#(ids)}]"#.utf8)
    }

    @Test func readwiseHighlightBodyMatchesTheV2API() throws {
        var h = HighlightTests.highlight("https://b.example/feed", "g", text: "the quote", color: .pink)
        h.note = "my note"
        let o = try json(try IntegrationRequests.readwiseHighlightBody(h))
        let item = try #require((o["highlights"] as? [[String: Any]])?.first)
        #expect(o.keys.sorted() == ["highlights"])
        #expect(item["text"] as? String == "the quote")
        #expect(item["title"] as? String == "Title g")
        #expect(item["author"] as? String == "Ada")
        #expect(item["source_url"] as? String == "https://example.com/g")
        #expect(item["source_type"] as? String == "opendispatch")
        #expect(item["category"] as? String == "articles")
        #expect(item["note"] as? String == "my note")
        #expect(item["highlighted_at"] as? String == ISO8601.string(from: h.createdAt))
        #expect(item["highlight_url"] as? String == "https://example.com/g#opendispatch-highlight-\(h.id)")

        h.note = ""
        h.itemAuthor = nil
        h.itemUrl = "https://example.com/g#frag"
        let bare = try #require((try json(try IntegrationRequests.readwiseHighlightBody(h))["highlights"] as? [[String: Any]])?.first)
        #expect(bare["note"] == nil)
        #expect(bare["author"] == nil)
        #expect(bare["highlight_url"] as? String == "https://example.com/g#opendispatch-highlight-\(h.id)")
    }

    @Test func newHighlightIsCreatedAndItsIdStored() async throws {
        let db = try Fixture.db()
        let h = HighlightTests.highlight("https://b.example/feed", "g", color: .blue)
        try await db.insertHighlight(h, forReadwise: true)
        IntegrationMockURLProtocol.reset { req, _ in
            req.httpMethod == "POST" ? (200, Self.response([555])) : (200, Data("{}".utf8))
        }
        let out = await sender(db).send()
        #expect(out == .init(sent: 1, deleted: 0, remaining: 0, error: nil))

        let sent = IntegrationMockURLProtocol.recorded.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent[0].request.httpMethod == "POST")
        #expect(sent[0].request.url?.absoluteString == "https://readwise.io/api/v2/highlights/")
        #expect(sent[0].request.value(forHTTPHeaderField: "Authorization") == "Token tok")
        // Create has no color field, so the color follows as an update of the new highlight.
        #expect(sent[1].request.httpMethod == "PATCH")
        #expect(sent[1].request.url?.absoluteString == "https://readwise.io/api/v2/highlights/555/")
        #expect(try json(sent[1].body) as? [String: String] == ["color": "blue"])

        let stored = try #require(try await db.highlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "g").first)
        #expect(stored.readwiseId == 555)
        #expect(!stored.readwisePending)
    }

    @Test func editsPatchTheNoteAndDeletesGoToReadwise() async throws {
        let db = try Fixture.db()
        var h = HighlightTests.highlight("https://b.example/feed", "g", color: .underline)
        h.readwiseId = 9
        try await db.insertHighlight(h)
        try await db.updateHighlight(id: h.id, note: "second thoughts", forReadwise: true)
        let gone = HighlightTests.highlight("https://b.example/feed", "h")
        var sentBefore = gone
        sentBefore.readwiseId = 10
        try await db.insertHighlight(sentBefore)
        try await db.deleteHighlight(id: sentBefore.id, forReadwise: true)

        IntegrationMockURLProtocol.reset { req, _ in (req.httpMethod == "DELETE" ? 204 : 200, Data()) }
        let out = await sender(db).send()
        #expect(out == .init(sent: 1, deleted: 1, remaining: 0, error: nil))
        let calls = IntegrationMockURLProtocol.recorded.withLock { $0 }.map { "\($0.request.httpMethod ?? "") \($0.request.url?.absoluteString ?? "")" }
        #expect(calls == ["DELETE https://readwise.io/api/v2/highlights/10/", "PATCH https://readwise.io/api/v2/highlights/9/"])
        // Underline has no Readwise color, so only the note is sent.
        let patch = try #require(IntegrationMockURLProtocol.recorded.withLock { $0 }.last)
        #expect(try json(patch.body) as? [String: String] == ["note": "second thoughts"])
    }

    @Test func aHighlightDeletedInReadwiseIsCreatedAgain() async throws {
        let db = try Fixture.db()
        var h = HighlightTests.highlight("https://b.example/feed", "g", color: .underline)
        h.readwiseId = 9
        try await db.insertHighlight(h, forReadwise: true)
        IntegrationMockURLProtocol.reset { req, _ in
            req.httpMethod == "PATCH" ? (404, Data(#"{"detail":"Not found."}"#.utf8)) : (200, Self.response([31]))
        }
        let out = await sender(db).send()
        #expect(out.sent == 1 && out.error == nil)
        #expect(try await db.highlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "g").first?.readwiseId == 31)
    }

    @Test func failuresLeaveTheWorkQueuedForNextTime() async throws {
        let db = try Fixture.db()
        let h = HighlightTests.highlight("https://b.example/feed", "g")
        try await db.insertHighlight(h, forReadwise: true)
        IntegrationMockURLProtocol.reset { _, _ in (500, Data("oops".utf8)) }
        let s = sender(db)
        var out = await s.send()
        #expect(out.sent == 0)
        #expect(out.remaining == 1)
        #expect(out.error == "Readwise returned 500: oops")
        #expect(await s.pendingCount() == 1)

        IntegrationMockURLProtocol.reset { _, _ in (429, Data()) }
        out = await s.send()
        #expect(out.error == "Readwise is rate limiting requests")

        // The next run (a later change or launch) sends it.
        IntegrationMockURLProtocol.reset { _, _ in (200, Self.response([8])) }
        out = await s.send()
        #expect(out == .init(sent: 1, deleted: 0, remaining: 0, error: nil))
    }

    @Test func nothingIsSentWithoutATokenOrForSyncedHighlights() async throws {
        let db = try Fixture.db()
        // Arrived through sync: not pending.
        try await db.insertHighlight(HighlightTests.highlight("https://b.example/feed", "synced"))
        IntegrationMockURLProtocol.reset { _, _ in (200, Self.response([1])) }
        #expect(await sender(db).send() == .init())
        #expect(IntegrationMockURLProtocol.recorded.withLock { $0 }.isEmpty)

        try await db.insertHighlight(HighlightTests.highlight("https://b.example/feed", "mine"), forReadwise: true)
        let out = await sender(db, token: nil).send()
        #expect(out.sent == 0 && out.remaining == 1 && out.error == nil)
        #expect(IntegrationMockURLProtocol.recorded.withLock { $0 }.isEmpty)
    }

    @Test func modifiedHighlightIDsAreReadFromTheResponse() {
        let data = Data(#"[{"id":1,"modified_highlights":[5,6]},{"id":2,"modified_highlights":[]}]"#.utf8)
        #expect(IntegrationRequests.modifiedHighlightIDs(data) == [5, 6])
        #expect(IntegrationRequests.modifiedHighlightIDs(Data("{}".utf8)).isEmpty)
    }
}
