import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("For You and Sources for you")
struct PersonalizationTests {
    /// Two sources with `n` rows each, the first's rows slightly newer, all published since the first open.
    private static func twoSources(_ db: AppDatabase, n: Int = 4) throws -> (loved: Source, skipped: Source) {
        let skipped = try Fixture.source(db, title: "Skipped", url: "https://skipped.example.com")
        let loved = try Fixture.source(db, title: "Loved", url: "https://loved.example.com")
        try Fixture.items(db, sourceId: skipped.id, Fixture.parsed(n, prefix: "s", step: -3600))
        try Fixture.items(db, sourceId: loved.id, Fixture.parsed(n, prefix: "l", start: Fixture.base.addingTimeInterval(-1800), step: -3600))
        return (loved, skipped)
    }

    private static func entry(url: String, feed: String = "https://x.example/feed", topic: String? = nil, content: String? = nil, outside: Bool = false) -> SourceSuggester.Opened {
        SourceSuggester.Opened(feedUrl: feed, sourceTitle: topic ?? "Source", itemUrl: url, content: content, topic: topic, isOutsideLibrary: outside)
    }

    // MARK: Order

    @Test func aSourceYouOpenRisesAndOneYouSkipFalls() async throws {
        let db = try Fixture.db()
        let now = Date()
        let skipped = try Fixture.source(db, title: "Skipped", url: "https://skipped.example.com")
        let loved = try Fixture.source(db, title: "Loved", url: "https://loved.example.com")
        // Skipped posts every hour from now back; Loved every hour from two hours ago. Opened a day ago, so all these count.
        try Fixture.items(db, sourceId: skipped.id, Fixture.parsed(30, prefix: "s", start: now, step: -3600))
        try Fixture.items(db, sourceId: loved.id, Fixture.parsed(30, prefix: "l", start: now.addingTimeInterval(-7200), step: -3600))
        let rows = try await db.items(ItemQuery(sourceId: loved.id, limit: 30)).items
        for row in rows.prefix(25) {
            try await db.writer.write { d in _ = try Queries.recordOpen(d, HistoryEntry(item: row), isMedia: false, now: now.addingTimeInterval(-86_400)) }
        }
        #expect(try await db.items(ItemQuery(order: .balanced)).items.first?.item.guid == "s0")
        let forYou = try await db.items(ItemQuery(order: .forYou)).items.map(\.item.guid)
        #expect(forYou.first == "l0")
        #expect(forYou.prefix(3).allSatisfy { $0.hasPrefix("l") })
        // Show Less gives some of it back.
        let less = try await db.items(ItemQuery(order: .forYou, sourcePreferences: [loved.feedUrl: -1])).items.map(\.item.guid)
        #expect(less.firstIndex(of: "s0")! < forYou.firstIndex(of: "s0")!)
    }

    @Test func aShiftIsCappedAndAPreferenceMovesIt() {
        let profile = ReadingProfile(affinities: ["a": SourceAffinity(opens: 90, published: 100, lift: 5), "b": SourceAffinity(opens: 1, published: 100, lift: -0.5)])
        #expect(profile.shiftHours(feedUrl: "a") == 12)
        #expect(profile.shiftHours(feedUrl: "b") == -3)
        #expect(profile.shiftHours(feedUrl: "b", preference: 1) == 3)
        #expect(profile.shiftHours(feedUrl: "b", preference: -1) == -9)
        #expect(profile.shiftHours(feedUrl: "unknown") == 0)
    }

    @Test func withLittleEvidenceASourceStaysNearAverage() {
        let thin = ReadingProfile.lift(opens: 1, published: 1, overall: 0.1)
        let strong = ReadingProfile.lift(opens: 40, published: 50, overall: 0.1)
        #expect(thin < 0.6)
        #expect(strong > 2)
        #expect(ReadingProfile.lift(opens: 0, published: 0, overall: 0.1) == 0)
    }

    @Test func showMoreAndShowLessWorkWithoutAnyHistory() async throws {
        let db = try Fixture.db()
        let (loved, skipped) = try Self.twoSources(db, n: 6)
        let shifted = try await db.items(ItemQuery(order: .forYou, sourcePreferences: [loved.feedUrl: 1, skipped.feedUrl: -1])).items.map(\.item.guid)
        #expect(shifted.first == "l0")
        #expect(shifted.firstIndex(of: "s0")! > 0)
    }

    @Test func aTopicsListIgnoresThePreferencesAndStaysBalanced() async throws {
        let db = try Fixture.db()
        let topic = try Fixture.source(db, title: "NFL", url: "https://topic.example.com", feedUrl: "opendispatch:topic:\(UUID().uuidString)", kind: .topic)
        try Fixture.items(db, sourceId: topic.id, Fixture.parsed(3, prefix: "t"))
        let balanced = try await db.items(ItemQuery(sourceId: topic.id, order: .balanced)).items.map(\.item.guid)
        let forYou = try await db.items(ItemQuery(sourceId: topic.id, order: .forYou, sourcePreferences: [topic.feedUrl: -1])).items.map(\.item.guid)
        #expect(forYou == balanced)
    }

    @Test func noHistoryIsAnEmptyProfile() async throws {
        let db = try Fixture.db()
        _ = try Self.twoSources(db)
        let profile = try await db.readingProfile()
        #expect(profile == .empty)
        let balanced = try await db.items(ItemQuery(order: .balanced)).items.map(\.item.guid)
        #expect(try await db.items(ItemQuery(order: .forYou)).items.map(\.item.guid) == balanced)
    }

    // MARK: What's recorded

    @Test func everyOpenIsKeptAndClearingHistoryClearsThem() async throws {
        let db = try Fixture.db()
        let (loved, _) = try Self.twoSources(db)
        let rows = try await db.items(ItemQuery(sourceId: loved.id)).items
        let t0 = Fixture.base
        for offset in [0.0, 60, 120] {
            try await db.writer.write { d in _ = try Queries.recordOpen(d, HistoryEntry(item: rows[0]), isMedia: false, now: t0.addingTimeInterval(offset)) }
        }
        let count = { try await db.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM open_events") ?? 0 } }
        #expect(try await count() == 3)
        try await db.writer.write { d in _ = try Queries.clearHistory(d, since: t0.addingTimeInterval(90)) }
        #expect(try await count() == 2)
        try await db.writer.write { d in _ = try Queries.clearHistory(d, since: nil) }
        #expect(try await count() == 0)
    }

    @Test func aRowSeenTwiceCountsOnce() async throws {
        let db = try Fixture.db()
        try await db.recordRowsSeen([(feedUrl: "f", guid: "a"), (feedUrl: "f", guid: "b")])
        try await db.recordRowsSeen([(feedUrl: "f", guid: "a")])
        #expect(try await db.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM rows_seen") } == 2)
    }

    @Test func removingASourceRemembersItAndAddingItBackForgets() async throws {
        let db = try Fixture.db()
        let source = try Fixture.source(db, title: "Gone", feedUrl: "https://gone.example.com/feed")
        let removed = { try await db.reader.read { d in try Queries.removedSourceKeys(d) } }
        try await db.writer.write { d in _ = try Queries.deleteSource(d, id: source.id) }
        #expect(try await removed() == ["gone.example.com/feed"])
        try Fixture.source(db, title: "Gone", feedUrl: "https://gone.example.com/feed")
        #expect(try await removed().isEmpty)
    }

    @Test func aTopicIsntRemembered() async throws {
        let db = try Fixture.db()
        let topic = try Fixture.source(db, title: "NFL", feedUrl: "opendispatch:topic:\(UUID().uuidString)", kind: .topic)
        try await db.writer.write { d in _ = try Queries.deleteSource(d, id: topic.id) }
        #expect(try await db.reader.read { d in try Queries.removedSourceKeys(d) }.isEmpty)
    }

    // MARK: Suggestions

    private static let noCatalog: [StarterPack] = []

    @Test func aCommunityOpenedThroughATopicIsSuggestedWithItsReason() {
        let opened = (0..<4).map { Self.entry(url: "https://www.reddit.com/r/firefox/comments/\($0)/x/", feed: "opendispatch:topic:a", topic: "Firefox", outside: true) }
        let out = SourceSuggester(opened: opened, followed: [], removed: [], catalog: Self.noCatalog).suggestions()
        #expect(out.count == 1)
        #expect(out[0].result.title == "r/firefox")
        #expect(out[0].result.feedUrl == "https://www.reddit.com/r/firefox/.rss")
        #expect(out[0].reason == "You opened 4 of its posts through your Firefox topic.")
        #expect(out[0].evidence == .opened)
    }

    @Test func oneOpenIsntEnough() {
        let opened = [Self.entry(url: "https://www.reddit.com/r/rivals/comments/1/x/")]
        #expect(SourceSuggester(opened: opened, followed: [], removed: [], catalog: Self.noCatalog).suggestions().isEmpty)
    }

    @Test func whatYouFollowOrRemovedIsntSuggested() {
        let opened = (0..<3).flatMap { i in
            [Self.entry(url: "https://www.reddit.com/r/nfl/comments/\(i)/x/"), Self.entry(url: "https://x.com/ProFootballTalk/status/\(i)")]
        }
        let followed = [SourceSuggester.Followed(feedUrl: "https://www.reddit.com/r/nfl/.rss", title: "r/nfl", host: "")]
        let out = SourceSuggester(opened: opened, followed: followed, removed: ["x.com/profootballtalk"], catalog: Self.noCatalog).suggestions()
        #expect(out.isEmpty)
    }

    @Test func aSourceRemovedUnderAnotherAddressStaysGone() {
        let pack = StarterPack(name: "NFL", sources: [
            StarterSource(title: "Pro Football Talk", host: "nbcsports.com", feedUrl: "https://profootballtalk.nbcsports.com/feed/"),
        ])
        let followed = [SourceSuggester.Followed(feedUrl: "https://nfl.example/feed", title: "NFL News", host: "nfl.example")]
        let bigger = StarterPack(name: "Sports", sources: pack.sources + [StarterSource(title: "NFL News", host: "nfl.example", feedUrl: "https://nfl.example/feed")])
        let opened = (0..<3).map { _ in Self.entry(url: "https://nfl.example/a", feed: "https://nfl.example/feed") }
        let kept = SourceSuggester(opened: opened, followed: followed, removed: [], catalog: [bigger], formats: []).suggestions()
        #expect(kept.map(\.result.title) == ["Pro Football Talk"])
        let out = SourceSuggester(opened: opened, followed: followed, removed: [], removedTitles: ["ProFootballTalk (@ProFootballTalk) on X"],
                                  catalog: [bigger], formats: []).suggestions()
        #expect(out.isEmpty)
    }

    @Test func anAccountFollowedUnderAnotherFeedIsntSuggested() {
        let opened = (0..<3).map { Self.entry(url: "https://x.com/claudeai/status/\($0)") }
        let followed = [SourceSuggester.Followed(feedUrl: "https://bsky.example/claude/rss", title: "Claude(@claudeai)", host: "")]
        #expect(SourceSuggester(opened: opened, followed: followed, removed: [], catalog: Self.noCatalog).suggestions().isEmpty)
    }

    @Test func aPublisherYouFollowDoesntComeBackAsItsChannel() {
        let npr = StarterSource(title: "NPR", host: "bsky.app", feedUrl: "https://bsky.app/profile/npr/rss", place: .bluesky)
        let body = #"<a href="https://www.npr.org/story">story</a>"#
        let opened = (0..<2).map { Self.entry(url: "https://a.example/\($0)", content: body) }
        let followed = [SourceSuggester.Followed(feedUrl: "https://feeds.npr.org/1001/rss.xml", title: "NPR News", host: "npr.org")]
        #expect(SourceSuggester(opened: opened, followed: followed, removed: [], catalog: [StarterPack(name: "Bluesky", sources: [npr])], formats: ["Bluesky"]).suggestions().isEmpty)
    }

    @Test func anOpenOutranksALink() {
        let body = #"<a href="https://x.com/linked/status/1">a</a>"#
        let opened = (0..<3).map { Self.entry(url: "https://a.example/\($0)", content: body) }
            + (0..<2).map { Self.entry(url: "https://www.reddit.com/r/opened/comments/\($0)/x/") }
        let out = SourceSuggester(opened: opened, followed: [], removed: [], catalog: Self.noCatalog).suggestions()
        #expect(out.map(\.result.title) == ["r/opened", "@linked"])
    }

    @Test func addressesThatArentAccountsOrThatOnlyEndLikeTheSiteDontCount() {
        #expect(SourceSuggester.postAuthor(in: "https://twitter.com/web/status/1") == nil)
        #expect(SourceSuggester.postAuthor(in: "https://twitter.com/user/status/1") == nil)
        #expect(SourceSuggester.postAuthor(in: "https://spacex.com/updates/status/1") == nil)
        #expect(SourceSuggester.postAuthor(in: "https://www.x.com/almonk/status/1") == "almonk")
        #expect(SourceSuggester.community(in: "https://notreddit.com/r/firefox/x") == nil)
        #expect(SourceSuggester.community(in: "https://old.reddit.com/r/firefox/x") == "firefox")
        #expect(SourceSuggester.linkedAccounts(in: "https://x.com/en/tos https://twitter.com/about https://twitter.com/statuses/1 https://x.com/opencode").map { $0 } == ["opencode"])
    }

    @Test func aCatalogAccountFollowedUnderAnotherFeedIsntSuggested() {
        let starter = StarterSource(title: "Anthropic", host: "x.com", feedUrl: "https://x.com/AnthropicAI", place: .x, detail: "X · @AnthropicAI")
        let member = StarterSource(title: "Mine", host: "mine.example", feedUrl: "https://mine.example/feed")
        let followed = [SourceSuggester.Followed(feedUrl: "https://mine.example/feed", title: "Mine (@AnthropicAI)", host: "mine.example")]
        let opened = (0..<3).map { _ in Self.entry(url: "https://mine.example/a", feed: "https://mine.example/feed") }
        let out = SourceSuggester(opened: opened, followed: followed, removed: [], catalog: [StarterPack(name: "AI", sources: [member, starter])], formats: []).suggestions()
        #expect(out.isEmpty)
    }

    @Test func accountsLinkedFromWhatYouOpenedAreSuggested() {
        let body = #"<a href="https://x.com/opencode/status/1">post</a> <a href="https://x.com/i/status/2">x</a> <a href="https://twitter.com/search?q=a">y</a>"#
        let opened = [Self.entry(url: "https://a.example/1", content: body), Self.entry(url: "https://a.example/2", content: body + body)]
        let out = SourceSuggester(opened: opened, followed: [], removed: [], catalog: Self.noCatalog).suggestions()
        #expect(out.map(\.result.title) == ["@opencode"])
        #expect(out[0].result.feedUrl == "https://x.com/opencode")
        #expect(out[0].reason == "Linked from 2 things you opened.")
    }

    @Test func aChannelNamedAfterALinkedSiteIsSuggested() {
        let lex = StarterSource(title: "Lex Fridman", host: "youtube.com", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=lex", place: .youtube, detail: "YouTube")
        let pack = StarterPack(name: "YouTube", sources: [lex])
        let body = #"<a href="https://lexfridman.com/podcast">site</a>"#
        let opened = [Self.entry(url: "https://youtube.com/watch?v=1", content: body), Self.entry(url: "https://youtube.com/watch?v=2", content: body)]
        let out = SourceSuggester(opened: opened, followed: [], removed: [], catalog: [pack], formats: ["YouTube"]).suggestions()
        #expect(out.map(\.result.title) == ["Lex Fridman"])
        #expect(out[0].starter == lex)
    }

    @Test func aPictureOrASubdomainDoesntNameASource() {
        let npr = StarterSource(title: "NPR", host: "bsky.app", feedUrl: "https://bsky.app/profile/npr/rss", place: .bluesky)
        let pack = StarterPack(name: "Bluesky", sources: [npr])
        let cdn = #"<a href="https://npr.brightspotcdn.com/a.jpg">a</a>"#
        let opened = (0..<3).map { Self.entry(url: "https://a.example/\($0)", content: cdn) }
        #expect(SourceSuggester(opened: opened, followed: [], removed: [], catalog: [pack], formats: ["Bluesky"]).suggestions().isEmpty)
        #expect(SourceSuggester.linkedHosts(in: #"<img src="https://a.example/1.png"> <a href="https://b.example/2">x</a> see https://c.example/3"#) == ["b.example", "c.example"])
    }

    @Test func aSiteIsSuggestedOnlyFromTheCatalog() {
        let opened = (0..<3).map { Self.entry(url: "https://unknown.example/\($0)", feed: "opendispatch:topic:a", topic: "NFL", outside: true) }
        #expect(SourceSuggester(opened: opened, followed: [], removed: [], catalog: Self.noCatalog).suggestions().isEmpty)
        let site = StarterSource(title: "Unknown", host: "unknown.example", feedUrl: "https://unknown.example/feed")
        let out = SourceSuggester(opened: opened, followed: [], removed: [], catalog: [StarterPack(name: "News", sources: [site])], formats: []).suggestions()
        #expect(out.first?.reason == "You opened 3 of its articles through your NFL topic.")
    }

    @Test func aSubjectYouReadSuggestsItsNeighboursNotOtherSubjects() {
        let nfl = StarterPack(name: "NFL", sources: [
            StarterSource(title: "ESPN NFL", host: "espn.com", feedUrl: "https://espn.com/nfl/rss"),
            StarterSource(title: "r/nfl", host: "reddit.com", feedUrl: "https://www.reddit.com/r/nfl/.rss", place: .reddit),
            StarterSource(title: "CBS NFL", host: "cbssports.com                ", feedUrl: "https://cbssports.com/nfl/rss"),
            StarterSource(title: "Third", host: "third.example", feedUrl: "https://third.example/rss"),
        ])
        let baseball = StarterPack(name: "Baseball", sources: [StarterSource(title: "MLB", host: "mlb.com", feedUrl: "https://mlb.com/rss")])
        let followed = [SourceSuggester.Followed(feedUrl: "https://www.reddit.com/r/nfl/.rss", title: "r/nfl", host: "")]
        let opened = (0..<3).map { Self.entry(url: "https://www.reddit.com/r/nfl/comments/\($0)/x/", feed: "https://www.reddit.com/r/nfl/.rss") }
        let out = SourceSuggester(opened: opened, followed: followed, removed: [], catalog: [nfl, baseball], formats: []).suggestions()
        #expect(out.map(\.result.title) == ["ESPN NFL", "CBS NFL"])
        #expect(out.allSatisfy { $0.evidence == .subject })
        #expect(out[0].reason == "Also in NFL, with r/nfl.")
        #expect(out[1].result.siteUrl == "https://cbssports.com")
    }

    @Test func aPublisherYouAlreadyReadIsntSuggestedAgainUnderAnotherFeed() {
        let pack = StarterPack(name: "Tech", sources: [
            StarterSource(title: "The Verge", host: "theverge.com", feedUrl: "https://www.theverge.com/rss/index.xml"),
        ])
        let followed = [SourceSuggester.Followed(feedUrl: "https://www.theverge.com/rss/ai.xml", title: "The Verge AI", host: "theverge.com")]
        let opened = (0..<3).map { _ in Self.entry(url: "https://www.theverge.com/a", feed: "https://www.theverge.com/rss/ai.xml") }
        #expect(SourceSuggester(opened: opened, followed: followed, removed: [], catalog: [pack], formats: []).suggestions().isEmpty)
    }

    @Test func readsSuggestionsFromTheDatabaseAndDismissingSticks() async throws {
        let db = try Fixture.db()
        let topic = try Fixture.source(db, title: "Firefox", feedUrl: "opendispatch:topic:\(UUID().uuidString)", kind: .topic)
        let parsed = (0..<2).map { i in ParsedItem(guid: "g\(i)", url: "https://www.reddit.com/r/firefox/comments/\(i)/x/", title: "T\(i)", publishedAt: Date()) }
        try Fixture.items(db, sourceId: topic.id, parsed)
        for row in try await db.items(ItemQuery(sourceId: topic.id)).items {
            try await db.writer.write { d in _ = try Queries.recordOpen(d, HistoryEntry(item: row), isMedia: false) }
        }
        let out = try await db.sourceSuggestions().filter { $0.result.title == "r/firefox" }
        let first = try #require(out.first)
        #expect(first.reason.hasSuffix("through your Firefox topic."))
        try await db.rememberRemovedSource(feedUrl: first.result.feedUrl, title: first.result.title)
        #expect(try await db.sourceSuggestions().contains { $0.result.title == "r/firefox" } == false)
    }

    @Test func theMigrationRemembersSourcesHistoryKnowsButTheLibraryDoesnt() async throws {
        let db = try Fixture.db()
        // A fresh database has run the migration with nothing to backfill; the same statement is what upgrades one.
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO history (source_feed_url, item_guid, item_url, item_title, source_title, source_kind, opened_at)
                VALUES ('https://x.com/ProFootballTalk', 'g', 'u', 't', 'ProFootballTalk', 'page', ?)
                """, arguments: [Fixture.base])
            try d.execute(sql: """
                INSERT OR IGNORE INTO removed_sources (feed_url, title, removed_at)
                  SELECT source_feed_url, MAX(source_title), MAX(COALESCE(opened_at, read_at)) FROM history
                  WHERE source_feed_url NOT LIKE 'opendispatch:%'
                    AND source_feed_url NOT IN (SELECT feed_url FROM sources)
                    AND COALESCE(opened_at, read_at) IS NOT NULL
                  GROUP BY source_feed_url
                """)
        }
        #expect(try await db.reader.read { d in try Queries.removedSourceKeys(d) } == ["x.com/profootballtalk"])
    }
}
