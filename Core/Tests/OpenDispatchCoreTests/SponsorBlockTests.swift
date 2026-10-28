import Foundation
import Testing
@testable import OpenDispatchCore

/// URLProtocol stub for the SponsorBlock client: one canned status and body for every request; logs the URLs.
/// Shared state, so the suite using it runs serialized.
final class SponsorBlockStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: (status: Int, body: String)?
    nonisolated(unsafe) private static var log: [String] = []

    /// `nil` fails the request (offline).
    static func reset(status: Int = 200, body: String = "[]", offline: Bool = false) {
        lock.lock(); reply = offline ? nil : (status, body); log = []; lock.unlock()
    }
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return log }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SponsorBlockStub.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.log.append(request.url?.absoluteString ?? "")
        let reply = Self.reply
        Self.lock.unlock()
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let res = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let sampleBody = """
[
  {"videoID":"otherVideo01","hash":"x","segments":[{"segment":[1,2],"UUID":"nope","category":"sponsor","actionType":"skip","videoDuration":10}]},
  {"videoID":"dQw4w9WgXcQ","hash":"y","segments":[
    {"segment":[10.5,40],"UUID":"u1","category":"sponsor","actionType":"skip","videoDuration":212.4,"votes":3},
    {"segment":[0,0],"UUID":"u2","category":"exclusive_access","actionType":"full","videoDuration":212.4},
    {"segment":[100,100],"UUID":"u3","category":"poi_highlight","actionType":"poi","videoDuration":212.4},
    {"segment":[60,61],"UUID":"u4","category":"interaction","actionType":"mute"},
    {"segment":[5],"UUID":"bad","category":"intro","actionType":"skip"}
  ]}
]
"""

@Suite("SponsorBlock: client (stubbed HTTP)", .serialized)
struct SponsorBlockClientTests {
    @Test func requestURL() {
        // sha256("dQw4w9WgXcQ") starts with 5f6b
        let url = DefaultSponsorBlock.url(videoID: "dQw4w9WgXcQ")
        #expect(url.hasPrefix("https://sponsor.ajay.app/api/skipSegments/5f6b?categories=%5B%22sponsor%22%2C%22selfpromo%22%2C"))
        #expect(url.contains("%22poi_highlight%22%2C%22exclusive_access%22%5D&actionTypes=%5B%22skip%22%2C%22mute%22%2C%22full%22%2C%22poi%22%5D&service=YouTube"))
    }

    @Test func picksTheMatchingVideo() async {
        SponsorBlockStub.reset(body: sampleBody)
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session())
        let segments = await client.segments(forVideoID: "dQw4w9WgXcQ")
        #expect(segments.map(\.uuid) == ["u1", "u2", "u3", "u4"])
        #expect(segments[0] == SponsorBlockSegment(start: 10.5, end: 40, category: "sponsor", actionType: "skip", uuid: "u1", videoDuration: 212.4))
        #expect(segments[3].actionType == "mute")
        #expect(segments[3].videoDuration == 0)
    }

    @Test func notFoundIsEmptyAndCached() async {
        SponsorBlockStub.reset(status: 404, body: "Not Found")
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session())
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").isEmpty)
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").isEmpty)
        #expect(SponsorBlockStub.requests().count == 1)
    }

    @Test func noEntryForTheVideoIsEmpty() async {
        SponsorBlockStub.reset(body: sampleBody)
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session())
        #expect(await client.segments(forVideoID: "aaaaaaaaaaa").isEmpty)
    }

    @Test func cachesForADay() async {
        SponsorBlockStub.reset(body: sampleBody)
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session(), now: { clock.now })
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").count == 4)
        clock.advance(23 * 3600)
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").count == 4)
        #expect(SponsorBlockStub.requests().count == 1)
        clock.advance(2 * 3600)
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").count == 4)
        #expect(SponsorBlockStub.requests().count == 2)
    }

    @Test func failuresAreEmptyAndNotCached() async {
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session())
        SponsorBlockStub.reset(offline: true)
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").isEmpty)
        SponsorBlockStub.reset(status: 503, body: "busy")
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").isEmpty)
        SponsorBlockStub.reset(body: "<html>not json</html>")
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").isEmpty)
        SponsorBlockStub.reset(body: sampleBody)
        #expect(await client.segments(forVideoID: "dQw4w9WgXcQ").count == 4)
    }

    @Test func rejectsMalformedVideoIDsWithoutAsking() async {
        SponsorBlockStub.reset(body: sampleBody)
        let client = DefaultSponsorBlock(session: SponsorBlockStub.session())
        #expect(await client.segments(forVideoID: "").isEmpty)
        #expect(await client.segments(forVideoID: "../etc/passwd").isEmpty)
        #expect(SponsorBlockStub.requests().isEmpty)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}

@Suite("SponsorBlock: player segments")
struct SponsorBlockPlayerTests {
    private func seg(_ s: Double, _ e: Double, _ category: String, _ action: String = "skip") -> SponsorBlockSegment {
        SponsorBlockSegment(start: s, end: e, category: category, actionType: action, uuid: "u", videoDuration: 100)
    }

    private func defaults(_ c: SponsorBlockCategory) -> SponsorBlockMode { c.defaultMode }

    @Test func defaultModes() {
        let modes = Dictionary(uniqueKeysWithValues: SponsorBlockCategory.allCases.map { ($0.rawValue, $0.defaultMode) })
        #expect(modes["sponsor"] == .skip && modes["selfpromo"] == .skip && modes["interaction"] == .skip)
        for id in ["intro", "outro", "preview", "hook", "poi_highlight", "exclusive_access"] { #expect(modes[id] == .show) }
        #expect(modes["filler"] == .off && modes["music_offtopic"] == .off)
        for c in SponsorBlockCategory.allCases { #expect(c.allowedModes.contains(c.defaultMode)) }
        #expect(SponsorBlockCategory.poiHighlight.allowedModes == [.show, .off])
        #expect(SponsorBlockCategory.musicOfftopic.allowedModes == [.skip, .show, .off])
    }

    @Test func disallowedModeFallsBackToDefault() {
        #expect(SponsorBlockCategory.poiHighlight.resolved(.skip) == .show)
        #expect(SponsorBlockCategory.sponsor.resolved(.mute) == .mute)
        #expect(SponsorBlockCategory.sponsor.resolved(nil) == .skip)
    }

    @Test func actionsFollowModeAndActionType() {
        let segments = [
            seg(50, 60, "intro"), seg(10, 20, "sponsor"), seg(30, 31, "interaction", "mute"), seg(70, 80, "selfpromo"),
            seg(0, 0, "exclusive_access", "full"), seg(90, 90, "poi_highlight", "poi"), seg(5, 6, "filler"),
        ]
        let out = SponsorBlock.playerSegments(segments) { c in c == .selfpromo ? .mute : c.defaultMode }
        #expect(out.map(\.category) == ["exclusive_access", "sponsor", "interaction", "intro", "selfpromo", "poi_highlight"])
        #expect(out.map(\.action) == [.full, .skip, .mute, .show, .mute, .poi])
        #expect(out[1].label == "sponsor" && out[1].color == "#00d400" && out[1].videoDuration == 100)
        #expect(out[3].label == "intro" && out[3].color == "#00ffff")
    }

    @Test func offDropsAndShowOverridesSkip() {
        let segments = [seg(10, 20, "sponsor"), seg(30, 40, "selfpromo")]
        let out = SponsorBlock.playerSegments(segments) { $0 == .sponsor ? .show : .off }
        #expect(out.count == 1 && out[0].action == .show && out[0].category == "sponsor")
    }

    @Test func dropsUnusableSegments() {
        let segments = [seg(20, 10, "sponsor"), seg(5, 5, "sponsor"), seg(-1, 4, "sponsor"), seg(1, 2, "bogus"), seg(.nan, 2, "sponsor")]
        #expect(SponsorBlock.playerSegments(segments, mode: defaults).isEmpty)
    }

    @Test func jsonShape() throws {
        let json = SponsorBlock.playerJSON(SponsorBlock.playerSegments([seg(10.5, 40, "sponsor")], mode: defaults))
        #expect(json == ##"[{"action":"skip","category":"sponsor","color":"#00d400","end":40,"label":"sponsor","start":10.5,"videoDuration":100}]"##)
        #expect(SponsorBlock.playerJSON([]) == "[]")
    }
}
