import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

/// Answers from a script, and records what it was asked.
private final class FakeEmbedCheck: YouTubeEmbedChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var inFlight = 0
    private(set) var peak = 0
    let answer: @Sendable (String) -> Bool?
    let delay: TimeInterval

    init(delay: TimeInterval = 0, answer: @escaping @Sendable (String) -> Bool? = { _ in true }) {
        self.delay = delay
        self.answer = answer
    }

    var videos: [String] { lock.withLock { asked } }

    func isPlayable(videoID: String) async -> Bool? {
        lock.withLock {
            asked.append(videoID)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if delay > 0 {
            // A cancelled check has no answer, like a cancelled request.
            guard (try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))) != nil else { return nil }
        }
        return answer(videoID)
    }

    func isPlayable(channelID: String) async -> Bool? { nil }
}

private enum Videos {
    static func source(_ db: AppDatabase, _ name: String = "UC1", folderId: Int64? = nil) throws -> Source {
        try Fixture.source(db, title: name, url: "https://www.youtube.com/channel/\(name)",
                           feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=\(name)", kind: .youtube, group: "youtube", folderId: folderId)
    }

    /// `ids` newest first, the first of them an hour old.
    static func feed(_ ids: [String], now: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        let entries = ids.enumerated().map { i, id -> String in
            let at = iso.string(from: now.addingTimeInterval(-3600 - Double(i) * 60))
            return """
                <entry><id>yt:video:\(id)</id><yt:videoId>\(id)</yt:videoId><title>Video \(id)</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=\(id)"/>
                <author><name>Channel</name></author><published>\(at)</published><updated>\(at)</updated></entry>
                """
        }.joined()
        return Data("""
            <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015" \
            xmlns:media="http://search.yahoo.com/mrss/"><title>Channel</title>\(entries)</feed>
            """.utf8)
    }

    /// Stored before any refresh in the test and not yet known, `ids` newest first.
    static func storeOld(_ db: AppDatabase, _ ids: [String], sourceId: Int64) throws {
        let items = ids.enumerated().map { i, id in
            ParsedItem(guid: "yt:video:\(id)", url: "https://www.youtube.com/watch?v=\(id)", title: "Video \(id)",
                       publishedAt: Date().addingTimeInterval(-7200 - Double(i) * 60), videoId: id)
        }
        try db.writer.write { d in
            _ = try Queries.upsertItems(d, sourceId: sourceId, items: items, now: Date().addingTimeInterval(-86_400))
        }
    }

    static func service(_ db: AppDatabase, check: any YouTubeEmbedChecking, budget: TimeInterval = DefaultRefreshService.embedCheckBudget,
                        feeds: @escaping @Sendable (String) async throws -> Data) -> DefaultRefreshService {
        DefaultRefreshService(database: db, parser: DefaultFeedParser(), scraper: NoScraper(), fetch: { url, _ in try await feeds(url) },
                              fallbacks: [:], embedCheck: check, embedCheckBudget: budget)
    }

    static func answers(_ db: AppDatabase) throws -> [String: Bool?] {
        try db.reader.read { d in
            let rows = try Item.fetchAll(d)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { item in item.videoId.map { ($0, item.embedBlocked) } })
        }
    }

    /// Stores videos with known answers (true: won't play) for the list tests.
    @discardableResult
    static func list(_ db: AppDatabase, sourceId: Int64, _ answers: [(String, Bool?)]) throws -> [Int64] {
        try db.writer.write { d in
            let items = answers.enumerated().map { i, answer in
                ParsedItem(guid: answer.0, url: "https://www.youtube.com/watch?v=\(answer.0)", title: answer.0,
                           publishedAt: Date().addingTimeInterval(-Double(i) * 60), videoId: answer.0)
            }
            let rows = try Queries.upsertItems(d, sourceId: sourceId, items: items)
            for (row, answer) in zip(rows, answers) {
                try d.execute(sql: "UPDATE items SET embed_blocked = ? WHERE id = ?", arguments: [answer.1, row.id])
            }
            return rows.map(\.id)
        }
    }
}

private struct NoScraper: PageScraper {
    func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult { throw HTTPError.status(404) }
    func findArticleLinks(html: String, pageURL: String) -> [String] { [] }
    func listingTitle(html: String, pageURL: String) -> String { "" }
    func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult { PageImageResult(image: nil, final: true) }
    func fetchLinkItem(url: String, videoID: String?, timeout: TimeInterval) async -> ParsedItem? { nil }
}

@Suite struct BlockedVideoStoreTests {
    @Test func migrationLeavesItemsUnknown() throws {
        let db = try Fixture.db()
        let columns = try db.reader.read { d in try d.columns(in: "items") }
        let column = try #require(columns.first { $0.name == "embed_blocked" })
        #expect(!column.isNotNull)
        #expect(column.defaultValueSQL == nil)
        let source = try Videos.source(db)
        try Videos.storeOld(db, ["a"], sourceId: source.id)
        #expect(try Videos.answers(db) == ["a": nil])
    }

    @Test func aRefreshOfTheFeedKeepsTheAnswer() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        try Videos.list(db, sourceId: source.id, [("a", true)])
        try db.writer.write { d in
            _ = try Queries.upsertItems(d, sourceId: source.id, items: [
                ParsedItem(guid: "a", url: "https://www.youtube.com/watch?v=a", title: "Renamed", publishedAt: Date(), videoId: "a"),
            ])
        }
        #expect(try Videos.answers(db) == ["a": true])
    }

    @Test func thePlayersAnswerStandsOverACheck() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let ids = try Videos.list(db, sourceId: source.id, [("a", nil), ("b", false)])
        try db.writer.write { d in
            try Queries.setVideoBlocked(d, itemId: ids[0])
            // The check that was running when the player failed comes back saying it plays.
            try Queries.storeEmbedChecks(d, playable: [ids[0]: true])
            // A video that was thought to play can still be found blocked.
            try Queries.setVideoBlocked(d, itemId: ids[1])
        }
        #expect(try Videos.answers(db) == ["a": true, "b": true])
    }

    @Test func aListRowCarriesTheAnswer() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let ids = try Videos.list(db, sourceId: source.id, [("a", true)])
        let row = try db.reader.read { d in try Queries.feedItem(d, id: ids[0]) }
        #expect(row?.item.embedBlocked == true)
    }

    /// Per device: another device has to find out for itself.
    @Test func theAnswerIsNotSynced() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let ids = try Videos.list(db, sourceId: source.id, [("a", true)])
        let item = try db.reader.read { d in try Item.fetchOne(d, key: ids[0]) }
        let record = SyncStore.savedItemRecord(try #require(item), sourceFeedUrl: source.feedUrl)
        #expect(!record.fields.keys.contains { $0.lowercased().contains("embed") || $0.lowercased().contains("blocked") })
    }
}

@Suite struct BlockedVideoRefreshTests {
    @Test func aRefreshChecksTheNewVideosOfAChannel() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let check = FakeEmbedCheck { $0 == "ok" }
        let svc = Videos.service(db, check: check) { _ in Videos.feed(["nope", "ok"]) }
        #expect(try await svc.refreshSource(id: source.id) == 2)
        #expect(Set(check.videos) == ["nope", "ok"])
        #expect(try Videos.answers(db) == ["nope": true, "ok": false])
    }

    @Test func refreshAllChecksEachChannelsVideos() async throws {
        let db = try Fixture.db()
        let one = try Videos.source(db, "UC1")
        let two = try Videos.source(db, "UC2")
        let check = FakeEmbedCheck()
        let svc = Videos.service(db, check: check) { url in
            Videos.feed(url.contains(one.feedUrl) ? ["a"] : url.contains(two.feedUrl) ? ["b"] : [])
        }
        let result = try await svc.refreshAll(force: true)
        #expect(result.results.allSatisfy { $0.ok })
        #expect(Set(check.videos) == ["a", "b"])
    }

    @Test func otherKindsOfSourceAreNotChecked() async throws {
        let db = try Fixture.db()
        let source = try Fixture.source(db)
        // A video in a site's feed would have an id too; only a channel's are asked about.
        try Videos.list(db, sourceId: source.id, [("x", nil)])
        let check = FakeEmbedCheck()
        let svc = Videos.service(db, check: check) { _ in
            Data("<rss version=\"2.0\"><channel><title>B</title><link>https://b.example.com</link></channel></rss>".utf8)
        }
        try await svc.refreshSource(id: source.id)
        #expect(check.videos.isEmpty)
    }

    @Test func aFailedCheckStaysUnknownAndIsAskedAgain() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let failing = FakeEmbedCheck { _ in nil }
        let feeds: @Sendable (String) async throws -> Data = { _ in Videos.feed(["a"]) }
        #expect(try await Videos.service(db, check: failing, feeds: feeds).refreshSource(id: source.id) == 1)
        #expect(try Videos.answers(db) == ["a": nil])
        #expect(try await db.source(id: source.id)?.lastError == nil)

        let working = FakeEmbedCheck { _ in false }
        #expect(try await Videos.service(db, check: working, feeds: feeds).refreshSource(id: source.id) == 0)
        #expect(working.videos == ["a"])
        #expect(try Videos.answers(db) == ["a": true])
    }

    @Test func aKnownAnswerIsNotAskedAgain() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let check = FakeEmbedCheck()
        let svc = Videos.service(db, check: check) { _ in Videos.feed(["a"]) }
        try await svc.refreshSource(id: source.id)
        try await svc.refreshSource(id: source.id)
        #expect(check.videos == ["a"])
    }

    @Test func aFeedThatFailsIsNotChecked() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        try Videos.storeOld(db, ["a"], sourceId: source.id)
        let check = FakeEmbedCheck()
        let svc = Videos.service(db, check: check) { _ in throw HTTPError.status(500) }
        await #expect(throws: (any Error).self) { try await svc.refreshSource(id: source.id) }
        let result = try await svc.refreshAll(force: true)
        #expect(result.results.allSatisfy { !$0.ok })
        #expect(check.videos.isEmpty)
    }

    /// A library from before this: five of the newest per channel each refresh, until it has caught up.
    @Test func backfillIsBoundedPerChannelAndNewestFirst() async throws {
        let db = try Fixture.db()
        let one = try Videos.source(db, "UC1")
        let two = try Videos.source(db, "UC2")
        let ones = (0..<8).map { "one\($0)" }
        let twos = (0..<7).map { "two\($0)" }
        try Videos.storeOld(db, ones, sourceId: one.id)
        try Videos.storeOld(db, twos, sourceId: two.id)
        #expect(DefaultRefreshService.embedBackfillCap == 5)

        let check = FakeEmbedCheck { _ in false }
        let svc = Videos.service(db, check: check) { _ in Videos.feed([]) }
        _ = try await svc.refreshAll(force: true)
        #expect(Set(check.videos) == Set(ones.prefix(5) + twos.prefix(5)))

        _ = try await svc.refreshAll(force: true)
        #expect(check.videos.count == 15)
        #expect(Set(check.videos) == Set(ones + twos))
        _ = try await svc.refreshAll(force: true)
        #expect(check.videos.count == 15)
    }

    @Test func newVideosComeOnTopOfTheBackfill() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let old = (0..<7).map { "old\($0)" }
        try Videos.storeOld(db, old, sourceId: source.id)
        let new = (0..<6).map { "new\($0)" }
        let check = FakeEmbedCheck()
        let svc = Videos.service(db, check: check) { _ in Videos.feed(new) }
        #expect(try await svc.refreshSource(id: source.id) == 6)
        #expect(Set(check.videos) == Set(new + old.prefix(5)))
    }

    @Test func newVideosAreAskedAboutFirst() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        try Videos.storeOld(db, ["old"], sourceId: source.id)
        let started = Date()
        try db.writer.write { d in
            _ = try Queries.upsertItems(d, sourceId: source.id, items: [
                // Published before the old one, yet only just stored.
                ParsedItem(guid: "new", url: "https://www.youtube.com/watch?v=new", title: "New",
                           publishedAt: Date().addingTimeInterval(-90_000), videoId: "new"),
            ])
        }
        let targets = try db.reader.read { d in
            try Queries.embedCheckTargets(d, sourceIds: [source.id], storedSince: started, backfill: 5)
        }
        #expect(targets.map(\.videoId) == ["new", "old"])
    }

    @Test func aRefreshAsksOnlyAFewAtATime() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let check = FakeEmbedCheck(delay: 0.02)
        let svc = Videos.service(db, check: check) { _ in Videos.feed((0..<12).map { "v\($0)" }) }
        try await svc.refreshSource(id: source.id)
        #expect(check.videos.count == 12)
        #expect(check.peak <= DefaultRefreshService.embedCheckConcurrency)
    }

    /// Slow checks don't hold the refresh past the budget, the answers that came are kept, and the rest stay unknown.
    @Test func aSlowNetworkCannotHoldTheRefresh() async throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        // One answers at once; the rest would take far longer than the refresh waits.
        let check = FakeEmbedCheck(delay: 30) { _ in false }
        let quick = PartlySlowCheck(quick: "v0", slow: check)
        let svc = Videos.service(db, check: quick, budget: 0.2) { _ in Videos.feed(["v0", "v1", "v2", "v3", "v4", "v5"]) }
        let started = Date()
        #expect(try await svc.refreshSource(id: source.id) == 6)
        #expect(Date().timeIntervalSince(started) < 5)
        let answers = try Videos.answers(db)
        #expect(answers["v0"] == true)
        #expect(answers.filter { $0.value != nil }.count == 1)
    }

}

/// One video answers straight away and the others wait on `slow`.
private struct PartlySlowCheck: YouTubeEmbedChecking {
    let quick: String
    let slow: FakeEmbedCheck

    func isPlayable(videoID: String) async -> Bool? {
        videoID == quick ? false : await slow.isPlayable(videoID: videoID)
    }

    func isPlayable(channelID: String) async -> Bool? { nil }
}

@Suite struct BlockedVideoHideTests {
    private func titles(_ page: ItemPage) -> [String] { page.items.map(\.item.title) }

    @Test func hideLeavesThemOutOfTheFeedsAndAFoldersAndASourcesList() throws {
        let db = try Fixture.db()
        let folder = try db.writer.write { d in try Queries.createFolder(d, title: "Sports") }
        let source = try Videos.source(db, folderId: folder.id)
        try Videos.list(db, sourceId: source.id, [("nope", true), ("ok", false), ("unknown", nil)])
        let shown = ["ok", "unknown"]
        for query in [ItemQuery(view: .all), ItemQuery(view: .video), ItemQuery(folderId: folder.id), ItemQuery(sourceId: source.id)] {
            var hiding = query
            hiding.hidesBlockedVideos = true
            #expect(try titles(db.reader.read { try Queries.items($0, hiding) }) == shown)
            #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, hiding) } == 1)
            #expect(try titles(db.reader.read { try Queries.items($0, query) }) == ["nope"] + shown)
            #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, query) } == 0)
        }
    }

    @Test func balancedOrderFollows() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        try Videos.list(db, sourceId: source.id, [("nope", true), ("ok", false)])
        let q = ItemQuery(view: .all, order: .balanced, hidesBlockedVideos: true)
        #expect(try titles(db.reader.read { try Queries.items($0, q) }) == ["ok"])
    }

    @Test func savedAndASearchStillShowThem() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let ids = try Videos.list(db, sourceId: source.id, [("nope", true), ("ok", false)])
        try db.writer.write { d in _ = try Queries.setSaved(d, itemId: ids[0], saved: true) }

        let saved = ItemQuery(view: .saved, hidesBlockedVideos: true)
        #expect(try titles(db.reader.read { try Queries.items($0, saved) }) == ["nope"])
        #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, saved) } == 0)

        let search = ItemQuery(view: .all, search: "nope", hidesBlockedVideos: true)
        #expect(try titles(db.reader.read { try Queries.items($0, search) }) == ["nope"])
        #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, search) } == 0)
    }

    /// The filter is in the query, so a page is full and the cursor walks past what's hidden.
    @Test func pagingStaysRight() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        let answers: [(String, Bool?)] = (0..<9).map { i in ("v\(i)", i % 3 == 0 ? true : false) }
        try Videos.list(db, sourceId: source.id, answers)
        var q = ItemQuery(sourceId: source.id, limit: 2, hidesBlockedVideos: true)
        var seen: [String] = []
        var pages = 0
        while true {
            let page = try db.reader.read { try Queries.items($0, q) }
            seen += titles(page)
            pages += 1
            guard let next = page.nextCursor else { break }
            #expect(page.items.count == 2)
            q = q.after(next)
        }
        #expect(seen == ["v1", "v2", "v4", "v5", "v7", "v8"])
        #expect(pages == 3)
        // However far the list has paged, the footer counts all of it.
        #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, q) } == 3)
    }

    @Test func aTopicsListIsLeftAlone() throws {
        let db = try Fixture.db()
        let source = try Videos.source(db)
        try Videos.list(db, sourceId: source.id, [("Firefox nope", true)])
        let topic = try db.writer.write { d in
            var options = TopicOptions(keyword: "Firefox")
            options.places.subscriptions = true
            var s = Source(title: "Firefox", url: "https://example.com", feedUrl: "opendispatch:topic:test", kind: .topic, group: "topic", topicOptions: options)
            try s.insert(d)
            return s
        }
        let q = ItemQuery(sourceId: topic.id, hidesBlockedVideos: true)
        #expect(try titles(db.reader.read { try Queries.items($0, q) }) == ["Firefox nope"])
        #expect(try db.reader.read { try Queries.hiddenBlockedVideoCount($0, q) } == 0)
    }
}

@Suite("Embed checks give up")
struct EmbedCheckGiveUpTests {
    @Test func unreadableAnswersStopTheRun() async {
        let check = FakeEmbedCheck(answer: { _ in nil })
        let targets = (0..<60).map { EmbedCheckTarget(id: Int64($0), videoId: "v\($0)") }
        let answers = await DefaultRefreshService.askPlayable(targets, check: check, concurrency: 4, budget: 5)
        #expect(answers.isEmpty)
        #expect(check.videos.count < 20)
    }

    @Test func oneAnswerKeepsItGoing() async {
        let check = FakeEmbedCheck(answer: { $0 == "v0" ? true : nil })
        let targets = (0..<30).map { EmbedCheckTarget(id: Int64($0), videoId: "v\($0)") }
        let answers = await DefaultRefreshService.askPlayable(targets, check: check, concurrency: 1, budget: 5)
        #expect(answers.count == 1)
        #expect(check.videos.count == 30)
    }
}
