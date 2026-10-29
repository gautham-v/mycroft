import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

// MARK: Helpers

/// Real headlines from the Firefox topic (Bing News, Oct 27-28 2026), by outlet.
private enum Headline {
    static let yahooVideo = "A new Firefox video reunites all your favorite early internet celebrities"
    static let coolDown = "Firefox ad takes aim at AI and tracking, drawing millions of views with a cast of meme legends"
    static let khou = "'The internet used to be fun': Firefox reunites 2000s meme stars for anti-AI ad"
    static let yahooMemes = "Firefox Just Reunited Some Of The Internet's Most Iconic Early Memes In A Nostalgic New Ad"
    static let betaNews = "Firefox Smart Window adds tab-based form filling and web page watching"
    static let nineToFive = "Firefox\u{2019}s AI-powered Smart Window gets form autofill and website monitoring"
    static let verge = "Firefox\u{2019}s Smart Window adds AI form filling and webpage monitoring"
    static let pcWorld = "Firefox 159 fixes 167 security flaws, including 13 sandbox escapes"
    static let securityWeek = "Chrome and Firefox Updates Patch Over 200 Vulnerabilities"
    static let releaseNote = "[Latest as of October 2026] Firefox 159 is officially released! A thorough explanation of the 167 vulnerability fixes"
}

private let storyBase = Fixture.base

private func article(_ guid: String, _ title: String, _ outlet: String, hoursAgo: Double, url: String? = nil) -> ParsedItem {
    ParsedItem(guid: guid, url: url ?? "https://\(guid).example.com/story", title: title, author: outlet,
               publishedAt: storyBase.addingTimeInterval(-hoursAgo * 3600))
}

private func thread(_ id: Int, _ title: String, url: String, points: Int, comments: Int, hoursAgo: Double) -> ParsedItem {
    ParsedItem(guid: "hn:\(id)", url: url, title: title, author: "Hacker News", publishedAt: storyBase.addingTimeInterval(-hoursAgo * 3600),
               hnPoints: points, hnComments: comments, hnCommentsUrl: "https://news.ycombinator.com/item?id=\(id)")
}

private func video(_ id: String, _ title: String, hoursAgo: Double) -> ParsedItem {
    ParsedItem(guid: "yt:\(id)", url: "https://www.youtube.com/watch?v=\(id)", title: title, author: "A Channel",
               publishedAt: storyBase.addingTimeInterval(-hoursAgo * 3600), videoId: id)
}

private func redditPost(_ id: String, _ title: String, hoursAgo: Double) -> ParsedItem {
    ParsedItem(guid: "reddit:\(id)", url: "https://www.reddit.com/r/firefox/comments/\(id)/x/", title: title, author: "r/firefox",
               publishedAt: storyBase.addingTimeInterval(-hoursAgo * 3600), hnPoints: 5, hnComments: 2)
}

private struct StoryScraper: PageScraper {
    func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult { throw HTTPError.status(404) }
    func findArticleLinks(html: String, pageURL: String) -> [String] { [] }
    func listingTitle(html: String, pageURL: String) -> String { "" }
    func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult { PageImageResult(image: nil, final: true) }
    func fetchLinkItem(url: String, videoID: String?, timeout: TimeInterval) async -> ParsedItem? { nil }
}

/// A topic search that answers from a script, one outcome per refresh, and from a table of Hacker News numbers.
private final class ScriptedSearch: TopicSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[ParsedItem]]
    private var asked: [[String]] = []
    var stats: [String: TopicHackerNewsStats]
    let languages: TopicLanguages

    init(_ rounds: [[ParsedItem]], stats: [String: TopicHackerNewsStats] = [:], languages: TopicLanguages = TopicFixtures.english) {
        self.rounds = rounds
        self.stats = stats
        self.languages = languages
    }

    var statsRequests: [[String]] { lock.lock(); defer { lock.unlock() }; return asked }

    func search(_ options: TopicOptions, subscriptions: TopicSubscriptions, now: Date) async -> TopicSearchOutcome {
        lock.lock(); defer { lock.unlock() }
        let items = rounds.isEmpty ? [] : rounds.removeFirst()
        return TopicSearchOutcome(items: items, searched: options.places.searched)
    }

    func hackerNewsStats(ids: [String]) async -> [String: TopicHackerNewsStats] {
        lock.lock(); defer { lock.unlock() }
        asked.append(ids)
        return stats.filter { ids.contains($0.key) }
    }
}

private func recent(_ guid: String, _ title: String, _ outlet: String, hoursAgo: Double, url: String? = nil) -> ParsedItem {
    ParsedItem(guid: guid, url: url ?? "https://\(guid).example.com/story", title: title, author: outlet,
               publishedAt: Date().addingTimeInterval(-hoursAgo * 3600))
}

private func recentThread(_ id: Int, _ title: String, url: String, points: Int, comments: Int, hoursAgo: Double) -> ParsedItem {
    ParsedItem(guid: "hn:\(id)", url: url, title: title, author: "Hacker News", publishedAt: Date().addingTimeInterval(-hoursAgo * 3600),
               hnPoints: points, hnComments: comments, hnCommentsUrl: "https://news.ycombinator.com/item?id=\(id)")
}

private func service(_ db: AppDatabase, _ search: any TopicSearching) -> DefaultRefreshService {
    DefaultRefreshService(
        database: db, parser: DefaultFeedParser(), scraper: StoryScraper(), fetch: { _, _ in throw HTTPError.status(404) },
        fallbacks: [:], feedTimeout: 15, concurrency: 4, topicSearch: search)
}

private func allItems(_ db: AppDatabase, _ topic: Source) throws -> [Item] {
    try db.reader.read { try Item.filter(Item.Columns.sourceId == topic.id).order(Item.Columns.id).fetchAll($0) }
}

private func group(_ db: AppDatabase, _ topic: Source) async throws {
    try await db.writer.write { d in
        let source = try #require(try Source.fetchOne(d, key: topic.id))
        try Queries.groupTopicStories(d, topic: source)
    }
}

private func rows(_ db: AppDatabase, _ topic: Source, _ filter: TopicContentFilter = .all) async throws -> [FeedItem] {
    try await db.items(ItemQuery(sourceId: topic.id, limit: 200, topicFilter: filter)).items
}

private func makeTopic(_ db: AppDatabase, _ keyword: String = "Firefox", places: TopicPlaces = TopicPlaces(subscriptions: false)) async throws -> Source {
    try await db.createTopic(TopicOptions(keyword: keyword, places: places))
}

// MARK: Rules

@Suite("Topic rules")
struct TopicRuleTests {
    @Test func redditIsItsOwnPlaceOffByDefault() throws {
        #expect(TopicPlaces.defaults == TopicPlaces(news: true, hackerNews: true, reddit: false, media: true, subscriptions: true))
        #expect(TopicPlaces().searched == [.news, .hackerNews, .media])
        #expect(TopicPlaces(reddit: true).searched == [.news, .hackerNews, .reddit, .media])
        #expect(TopicOptions(keyword: "x").places.reddit == false)
    }

    @Test func oldDiscussionsKeyReadsAsHackerNewsAndRedditStaysOff() throws {
        // The Firefox topic as the first version stored it.
        let stored = #"{"excluded":[],"keyword":"Firefox","notableOnly":false,"places":{"discussions":true,"media":true,"news":true,"subscriptions":true},"skipPaywalled":true}"#
        let o = try #require(TopicOptions(json: stored))
        #expect(o.places == TopicPlaces(news: true, hackerNews: true, reddit: false, media: true, subscriptions: true))

        let off = try #require(TopicOptions(json: #"{"keyword":"x","places":{"discussions":false}}"#))
        #expect(!off.places.hackerNews && !off.places.reddit)

        // The new keys win over the old one, and Reddit is on only when it is stored.
        let both = try #require(TopicOptions(json: #"{"keyword":"x","places":{"discussions":false,"hackerNews":true,"reddit":true}}"#))
        #expect(both.places.hackerNews && both.places.reddit)
        let none = try #require(TopicOptions(json: #"{"keyword":"x","places":{}}"#))
        #expect(none.places == .defaults)
    }

    @Test func placesEncodeWithTheNewKeysOnlyAndRoundTrip() throws {
        let o = TopicOptions(keyword: "x", places: TopicPlaces(news: false, hackerNews: true, reddit: true, media: false, subscriptions: true))
        #expect(o.json.contains(#""places":{"hackerNews":true,"media":false,"news":false,"reddit":true,"subscriptions":true}"#))
        #expect(!o.json.contains("discussions"))
        #expect(TopicOptions(json: o.json) == o)
    }

    @Test func oldOptionsSurviveASyncRecordAndStayHackerNewsOnly() async throws {
        let db = try Fixture.db()
        // A topic row written by the first version: `discussions` in the stored options.
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO sources (title, url, feed_url, kind, "group", position, topic_options)
                VALUES ('Firefox', ?, ?, 'topic', 'topics', 0, ?)
                """, arguments: [Topic.siteURL, Topic.newFeedURL(), #"{"keyword":"Firefox","places":{"discussions":true,"media":true,"news":true,"subscriptions":true}}"#])
        }
        let t = try #require(try await db.topics().first)
        #expect(t.topicOptions?.places.hackerNews == true && t.topicOptions?.places.reddit == false)
    }

    @Test func theKeywordMustBeInTheTitleForEveryPlace() {
        func candidate(_ title: String, summary: String? = nil, url: String = "https://example.com/a") -> DefaultTopicSearch.Candidate {
            DefaultTopicSearch.Candidate(
                item: ParsedItem(guid: url + title, url: url, title: title, summary: summary, publishedAt: TopicFixtures.now.addingTimeInterval(-3600)),
                host: URLHost.host(of: url))
        }
        let out = DefaultTopicSearch.finish([
            candidate("Firefox ships a thing"),
            candidate("Harness Corp, an incremental game", summary: "Runs in Firefox with WebGPU"),
            candidate("Show HN: A thing", url: "https://www.firefox.com/en-US/blog"),
            candidate("Firefox rumor roundup", summary: nil),
        ], TopicOptions(keyword: "Firefox", excluded: ["rumor"]), TopicMatcher(keyword: "Firefox", excluded: ["rumor"]), .empty, TopicFixtures.now, checkPaywall: false)
        #expect(out.map(\.title) == ["Firefox ships a thing"])
    }

    @Test func leaveOutWordsAreCheckedInTheSummaryToo() {
        let candidate = DefaultTopicSearch.Candidate(item: ParsedItem(
            guid: "g", url: "https://example.com/a", title: "Firefox ships a thing", summary: "<p>A GIVEAWAY inside</p>",
            publishedAt: TopicFixtures.now.addingTimeInterval(-3600)))
        let o = TopicOptions(keyword: "Firefox", excluded: ["giveaway"])
        #expect(DefaultTopicSearch.finish([candidate], o, TopicMatcher(o), .empty, TopicFixtures.now, checkPaywall: false).isEmpty)
    }

    @Test func languagesAreTheReadersAndBingGetsTheirMarket() {
        let us = TopicLanguages(preferred: ["en-US"], region: "US")
        #expect(us.codes == ["en"] && us.market == "en-US")
        #expect(TopicLanguages(preferred: ["en-GB", "fr-FR"], region: "US").market == "en-GB")
        #expect(TopicLanguages(preferred: ["es"], region: "US").market == "es-US")
        #expect(TopicLanguages(preferred: ["zh-Hans-CN"], region: nil).codes == ["zh"])
        #expect(TopicLanguages(preferred: ["de"], region: nil).market == nil)
    }

    @Test func titlesInOtherLanguagesAreRejected() {
        let en = TopicFixtures.english
        // The foreign titles of the Firefox topic.
        #expect(en.rejects("\u{03A4}\u{03BF} Firefox 159 \u{03B4}\u{03B9}\u{03BF}\u{03C1}\u{03B8}\u{03CE}\u{03BD}\u{03B5}\u{03B9} 167 \u{03B5}\u{03C5}\u{03C0}\u{03AC}\u{03B8}\u{03B5}\u{03B9}\u{03B5}\u{03C2}, \u{03BF}\u{03B9} 41 \u{03B5}\u{03BD}\u{03C4}\u{03BF}\u{03C0}\u{03AF}\u{03C3}\u{03C4}\u{03B7}\u{03BA}\u{03B1}\u{03BD} \u{03B1}\u{03C0}\u{03CC} \u{03B5}\u{03C1}\u{03B3}\u{03B1}\u{03BB}\u{03B5}\u{03AF}\u{03B1} \u{03C4}\u{03B7}\u{03C2} OpenAI"))
        #expect(en.rejects("549. \u{041D}\u{043E}\u{0432}\u{0438}\u{043D}\u{043A}\u{0438} Firefox 158 \u{0438} Enterprise, \u{0438}\u{0437} Electron \u{0432} PWA \u{0438} \u{043E}\u{0431}\u{0440}\u{0430}\u{0442}\u{043D}\u{043E}, JPEG XL \u{043F}\u{0440}\u{043E}\u{0442}\u{0438}\u{0432} AVIF \u{0438} \u{0438}\u{043A}\u{043E}\u{043D}\u{043A}\u{0438}"))
        #expect(en.rejects("\u{3010}2026\u{5E74}10\u{6708}\u{6700}\u{65B0}\u{3011}Firefox 159\u{304C}\u{6B63}\u{5F0F}\u{30EA}\u{30EA}\u{30FC}\u{30B9}\u{FF01}\u{5927}\u{91CF}167\u{4EF6}\u{306E}\u{8106}\u{5F31}\u{6027}\u{4FEE}\u{6B63}"))
        #expect(en.rejects("Consejo para bajar juegos sin que me hackeen?"))
        #expect(en.rejects("Firefox-Container trennen Arbeit, Shopping und Privates"))
    }

    @Test func englishAndShortTitlesAreKept() {
        let en = TopicFixtures.english
        for title in [Headline.yahooVideo, Headline.khou, Headline.verge, "Firefox Auto-Run on Windows", "Recover lost text by coredumping Firefox",
                      "Firefox \u{2013} Site Isolation (Fission) Goes Live on Android", "Firefox Gold - Expanding the High-Grade Footprint",
                      "Firefox 159", "Si", "12345 67890 1234", ""] {
            #expect(!en.rejects(title), "\(title)")
        }
        // A reader of Greek keeps Greek, and no languages keep everything.
        #expect(!TopicLanguages(preferred: ["el-GR"], region: "GR").rejects("\u{03A4}\u{03BF} Firefox 159 \u{03B4}\u{03B9}\u{03BF}\u{03C1}\u{03B8}\u{03CE}\u{03BD}\u{03B5}\u{03B9} \u{03B5}\u{03C5}\u{03C0}\u{03AC}\u{03B8}\u{03B5}\u{03B9}\u{03B5}\u{03C2}"))
        #expect(!TopicLanguages(preferred: [], region: nil).rejects("Consejo para bajar juegos sin que me hackeen?"))
    }

    @Test func aSearchDropsTitlesInOtherLanguages() async throws {
        let o = TopicOptions(keyword: "Firefox")
        let spanish = DefaultTopicSearch.Candidate(item: ParsedItem(
            guid: "es", url: "https://example.com/es", title: "Firefox: consejo para bajar juegos sin que me hackeen", publishedAt: TopicFixtures.now.addingTimeInterval(-3600)))
        let english = DefaultTopicSearch.Candidate(item: ParsedItem(
            guid: "en", url: "https://example.com/en", title: "Firefox: a tip for installing games safely", publishedAt: TopicFixtures.now.addingTimeInterval(-3600)))
        let kept = DefaultTopicSearch.finish([spanish, english], o, TopicMatcher(o), .empty, TopicFixtures.now, checkPaywall: false, languages: TopicFixtures.english)
        #expect(kept.map(\.guid) == ["en"])
        let all = DefaultTopicSearch.finish([spanish, english], o, TopicMatcher(o), .empty, TopicFixtures.now, checkPaywall: false)
        #expect(all.count == 2)
    }

    @Test func hackerNewsNumbersComeFromOneAlgoliaRequest() async throws {
        let url = DefaultTopicSearch.hackerNewsStatsURL(ids: ["50276099", "50259191"])
        #expect(url.hasPrefix("https://hn.algolia.com/api/v1/search?tags=%28story_50276099%2Cstory_50259191%29&hitsPerPage=100"))
        let body = Data(#"{"hits":[{"objectID":"50276099","points":12,"num_comments":9},{"objectID":"50259191","points":null,"num_comments":4}]}"#.utf8)
        let parsed = try DefaultTopicSearch.parseHackerNewsStats(body)
        #expect(parsed == ["50276099": TopicHackerNewsStats(points: 12, comments: 9), "50259191": TopicHackerNewsStats(points: 0, comments: 4)])

        let net = TopicFixtures.Network([.init(fragment: "hn.algolia.com", status: 200, body: body)])
        let stats = await net.search().hackerNewsStats(ids: ["50276099", "50259191"])
        #expect(stats["50276099"] == TopicHackerNewsStats(points: 12, comments: 9))
        #expect(net.requests(containing: "hn.algolia.com").count == 1)

        // Many stories go in batches; a batch that fails leaves its stories out.
        let ids = (0..<250).map(String.init)
        let failing = TopicFixtures.Network([], failing: ["hn.algolia.com"])
        #expect(await failing.search().hackerNewsStats(ids: ids).isEmpty)
        #expect(failing.requests(containing: "hn.algolia.com").count == 3)
        let refused = TopicFixtures.Network([.init(fragment: "hn.algolia.com", status: 500, body: Data())])
        #expect(await refused.search().hackerNewsStats(ids: ["1"]).isEmpty)
    }
}

// MARK: Stories

@Suite("Topic stories")
struct TopicStoryTests {
    @Test func wordsDropTheKeywordStopWordsAndPunctuation() {
        let words = TopicStories.words(of: Headline.khou, keyword: "Firefox")
        #expect(words == ["internet", "used", "fun", "reunit", "2000", "meme", "star", "anti", "ai", "ad"])
        // Plurals and tenses line up, accents and curly quotes don't matter, and the topic's own words never count.
        #expect(TopicStories.words(of: "Firefox reunites memes", keyword: "firefox") == TopicStories.words(of: "Firefox\u{2019}s Reunited MEME", keyword: "Firefox"))
        #expect(TopicStories.words(of: "Show HN: Caf\u{00E9} Vision Pro", keyword: "vision pro") == ["cafe"])
    }

    @Test func sameStoryNeedsSharedWordsInsideTheWindow() {
        let a = TopicStories.words(of: Headline.verge, keyword: "Firefox")
        let b = TopicStories.words(of: Headline.betaNews, keyword: "Firefox")
        let t = Fixture.base
        #expect(TopicStories.isSameStory(a, t, b, t.addingTimeInterval(86_400)))
        #expect(!TopicStories.isSameStory(a, t, b, t.addingTimeInterval(4 * 86_400)))
        // Different stories on the same product.
        let fixes = TopicStories.words(of: Headline.pcWorld, keyword: "Firefox")
        let patches = TopicStories.words(of: Headline.securityWeek, keyword: "Firefox")
        #expect(!TopicStories.isSameStory(a, t, fixes, t))
        #expect(!TopicStories.isSameStory(fixes, t, patches, t))
        #expect(!TopicStories.overlaps([], ["x"]))
    }

    @Test func outletsCoveringOneStoryBecomeOneRow() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        // Stored newest first, as a search answers.
        try Fixture.items(db, sourceId: t.id, [
            article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 40),
            article("khou", Headline.khou, "KHOU", hoursAgo: 30),
            article("beta", Headline.betaNews, "BetaNews", hoursAgo: 20),
            article("cooldown", Headline.coolDown, "The Cool Down on MSN", hoursAgo: 18),
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 12),
            article("nine", Headline.nineToFive, "9to5Mac", hoursAgo: 10),
            article("verge", Headline.verge, "The Verge", hoursAgo: 5),
            article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 3),
            article("security", Headline.securityWeek, "SecurityWeek", hoursAgo: 2),
        ])
        try await group(db, t)

        let list = try await rows(db, t)
        // Newest coverage first: SecurityWeek and PCWorld alone, Smart Window (BetaNews led it; The Verge is its newest article), the
        // meme ad (Yahoo led it) and The Cool Down, whose headline shares too few words with the others to join.
        #expect(list.map(\.item.guid) == ["security", "pcworld", "beta", "yahoo2", "cooldown"])
        let smart = try #require(list.first { $0.item.guid == "beta" })
        let meme = try #require(list.first { $0.item.guid == "yahoo2" })
        // The lead is the first stored; the others follow it, newest first.
        #expect(smart.story?.outlets.map(\.name) == ["BetaNews", "The Verge", "9to5Mac"])
        #expect(meme.story?.outlets.map(\.name) == ["Yahoo", "Yahoo", "KHOU"])
        #expect(meme.story?.outlets.first?.id == meme.item.id)
        #expect(meme.story?.others.map(\.title) == [Headline.yahooVideo, Headline.khou])
        #expect(meme.story?.outlets.last?.host == "khou.example.com")
        // Lone articles carry no story.
        #expect(list.first { $0.item.guid == "pcworld" }?.story == nil)
        #expect(list.first { $0.item.guid == "cooldown" }?.story == nil)
    }

    @Test func storiesAreSavedAndKeepTheirLeadWhenMoreCoverageArrives() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26)])
        try await group(db, t)
        let before = try allItems(db, t)
        #expect(before.map(\.storyId) == [nil, before[0].id])
        #expect(before[0].storyAt == storyBase.addingTimeInterval(-26 * 3600))

        // Another outlet an hour ago: it joins the same story (a bridging headline included), the lead stays.
        try Fixture.items(db, sourceId: t.id, [article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 1)])
        try await group(db, t)
        let after = try allItems(db, t)
        #expect(after.map(\.storyId) == [nil, before[0].id, before[0].id])
        // The story sorts by its newest article, so fresh coverage lifts it.
        #expect(after[0].storyAt == storyBase.addingTimeInterval(-3600))
        #expect(try await rows(db, t).map(\.item.guid) == ["khou"])
        // Grouping again changes nothing.
        try await group(db, t)
        #expect(try allItems(db, t).map(\.storyId) == after.map(\.storyId))
    }

    @Test func aHeadlineThatLinksTwoEarlierOnesPullsBothIn() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        // yahoo1 matches yahoo2 but not khou; yahoo2 matches both. Stored in this order, yahoo1 can only join once yahoo2 is in.
        try Fixture.items(db, sourceId: t.id, [
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 30), article("khou", Headline.khou, "KHOU", hoursAgo: 28),
            article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26)])
        try await group(db, t)
        let list = try await rows(db, t)
        #expect(list.count == 1)
        #expect(list[0].story?.outlets.count == 3)
    }

    @Test func twoStoriesBecomeOneWhenAnArticleLinksThemAndAReadStoryStaysRead() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("a1", "Firefox launches the alpha nebula widget", "One", hoursAgo: 30),
            article("a2", "Firefox alpha nebula widget arrives today", "Two", hoursAgo: 29),
            article("b1", "Firefox gamma orion gadget ships", "Three", hoursAgo: 28),
            article("b2", "Firefox gamma orion gadget lands", "Four", hoursAgo: 27)])
        try await group(db, t)
        #expect(try await rows(db, t).count == 2)
        let b = try #require(try await rows(db, t).first { $0.item.guid == "b1" })
        try await db.recordOpen(HistoryEntry(item: b), isMedia: false)
        #expect(try await db.unreadCounts()[t.id] == 1)

        // Coverage of both: one story now, led by its earliest article, and read since half of it was.
        try Fixture.items(db, sourceId: t.id, [
            article("c", "Firefox alpha nebula widget meets the gamma orion gadget", "Five", hoursAgo: 26)])
        try await group(db, t)
        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["a1"])
        #expect(list[0].story?.outlets.count == 5)
        #expect(try await db.unreadCounts()[t.id] == nil)
    }

    @Test func launchTidiesWhatAnOlderBuildStored() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("verge", Headline.verge, "The Verge", hoursAgo: 20), article("beta", Headline.betaNews, "BetaNews", hoursAgo: 19),
            article("body", "A browser roundup that mentions it in passing", "Somewhere", hoursAgo: 10),
            redditPost("1", "Firefox keeps crashing", hoursAgo: 5)])
        #expect(try await rows(db, t).count == 4)
        #expect(try await db.tidyTopics(languages: TopicLanguages(preferred: ["en-US"], region: "US")) == 2)
        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["verge"])
        #expect(list[0].story?.outlets.count == 2)
    }

    @Test func articlesDaysApartAreDifferentStories() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [article("a", Headline.verge, "The Verge", hoursAgo: 5 * 24), article("b", Headline.betaNews, "BetaNews", hoursAgo: 1)])
        try await group(db, t)
        #expect(try await rows(db, t).count == 2)
        #expect(try await rows(db, t).allSatisfy { $0.story == nil })
    }

    @Test func aStoryListsOnceAndPagesWithoutRepeatsOrGaps() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("lead", Headline.khou, "KHOU", hoursAgo: 60), article("later", Headline.yahooMemes, "Yahoo", hoursAgo: 2),
            article("s1", "Firefox adds one thing for testers today", "Outlet A", hoursAgo: 10),
            article("s2", "Mozilla changes the toolbar layout somehow", "Outlet B", hoursAgo: 20),
            article("s3", "Add-on review queue is shorter this autumn", "Outlet C", hoursAgo: 30),
            article("s4", "Developers complain about the new sidebar", "Outlet D", hoursAgo: 40),
            video("vid", "Firefox video review", hoursAgo: 50)])
        try await group(db, t)
        let full = try await rows(db, t).map(\.item.guid)
        // The story sits where its newest article is (2h), above the 10h article although its lead is 60h old.
        #expect(full == ["lead", "s1", "s2", "s3", "s4", "yt:vid"])
        var paged: [String] = []
        var q = ItemQuery(sourceId: t.id, limit: 2)
        while true {
            let page = try await db.items(q)
            paged += page.items.map(\.item.guid)
            guard let next = page.nextCursor else { break }
            q = q.after(next)
        }
        #expect(paged == full)
        // The lead's cursor is its story's time, so the next page starts below the story, not below its lead.
        let first = try await db.items(ItemQuery(sourceId: t.id, limit: 1))
        #expect(first.nextCursor?.publishedAt == storyBase.addingTimeInterval(-2 * 3600))
    }

    @Test func hackerNewsThreadsJoinTheirStoryByLinkOrTitle() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("verge", Headline.verge, "The Verge", hoursAgo: 20, url: "https://www.theverge.com/ai/1019551/firefox-smart-window"),
            article("beta", Headline.betaNews, "BetaNews", hoursAgo: 19),
            article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 8, url: "https://www.pcworld.com/article/3271386/fixes.html"),
            article("lone", "Firefox gets a quiet new settings page for container tabs", "Ghacks", hoursAgo: 6),
            // By address (www., trailing slash and tracking ignored, a title that shares nothing).
            thread(1, "Smart Window is out", url: "https://theverge.com/ai/1019551/firefox-smart-window/?utm_source=hn", points: 10, comments: 4, hoursAgo: 15),
            // By title.
            thread(2, "Firefox 159 fixes 167 security flaws including 13 sandbox escapes (PCWorld)", url: "https://example.org/other", points: 3, comments: 0, hoursAgo: 7),
            // A thread about nothing in the list stays a row of its own.
            thread(3, "Tell HN: I know Firefox has update when it starts to glitch", url: "https://news.ycombinator.com/item?id=3", points: 1, comments: 3, hoursAgo: 4),
            // A second thread about the first story: the one with more points shows.
            thread(4, "Firefox\u{2019}s Smart Window adds AI form filling and webpage monitoring", url: "https://example.org/x", points: 2, comments: 1, hoursAgo: 14),
        ])
        try await group(db, t)

        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["hn:3", "lone", "pcworld", "verge"])
        let smart = try #require(list.first { $0.item.guid == "verge" })
        let firstThread = try #require(try allItems(db, t).first { $0.guid == "hn:1" })
        #expect(smart.story?.discussion == TopicDiscussion(id: firstThread.id, points: 10, comments: 4, url: "https://news.ycombinator.com/item?id=1"))
        #expect(smart.story?.outlets.map(\.name) == ["The Verge", "BetaNews"])
        #expect(list.first { $0.item.guid == "hn:3" }?.story == nil)
        let fixes = try #require(list.first { $0.item.guid == "pcworld" })
        #expect(fixes.story?.discussion?.points == 3 && fixes.story?.outlets.count == 1)
        // The discussions filter lists only the thread with no story.
        #expect(try await rows(db, t, .discussions).map(\.item.guid) == ["hn:3"])
        #expect(try await rows(db, t, .news).map(\.item.guid).sorted() == ["lone", "pcworld", "verge"])
    }

    @Test func aThreadStoredBeforeItsArticleJoinsWhenTheArticleArrives() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [thread(7, "Smart Window", url: "https://www.theverge.com/a/b", points: 5, comments: 2, hoursAgo: 3)])
        try await group(db, t)
        #expect(try await rows(db, t).map(\.item.guid) == ["hn:7"])
        try Fixture.items(db, sourceId: t.id, [article("verge", Headline.verge, "The Verge", hoursAgo: 2, url: "https://theverge.com/a/b")])
        try await group(db, t)
        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["verge"])
        #expect(list[0].story?.discussion?.points == 5)
        // The story's lead is the article, never a thread, and a story with only a thread behind it has the one outlet.
        #expect(list[0].story?.outlets.count == 1)
    }

    @Test func videosEpisodesAndRedditStayRowsOfTheirOwn() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db, places: TopicPlaces(reddit: true, subscriptions: false))
        try Fixture.items(db, sourceId: t.id, [
            article("verge", Headline.verge, "The Verge", hoursAgo: 20),
            video("v1", Headline.verge, hoursAgo: 19),
            redditPost("r1", Headline.verge, hoursAgo: 18),
            ParsedItem(guid: "https://podcasts.apple.com/e/1", url: "https://podcasts.apple.com/e/1", title: Headline.verge, author: "A Show",
                       publishedAt: storyBase.addingTimeInterval(-17 * 3600), audioUrl: "https://example.com/a.mp3"),
        ])
        try await group(db, t)
        #expect(try await rows(db, t).count == 4)
        #expect(try allItems(db, t).allSatisfy { $0.storyId == nil })
        #expect(try await rows(db, t, .discussions).map(\.item.guid) == ["reddit:r1"])
        #expect(try await rows(db, t, .videos).map(\.item.guid) == ["yt:v1"])
        #expect(try await rows(db, t, .episodes).count == 1)
    }

    @Test func filtersAndTheirCountsCountRows() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db, places: TopicPlaces(reddit: true, subscriptions: false))
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26),
            article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 8),
            thread(1, "Come Back to Firefox. Meta Never Left", url: "https://example.org/meta", points: 4, comments: 1, hoursAgo: 7),
            thread(2, "The internet used to be fun, Firefox reunites memes", url: "https://example.org/fun", points: 4, comments: 1, hoursAgo: 25),
            redditPost("r1", "Firefox question", hoursAgo: 6),
            video("v1", "Firefox video", hoursAgo: 5), video("v2", "Firefox video two", hoursAgo: 4),
        ])
        try await group(db, t)
        let counts = try await db.topicFilterCounts(topicId: t.id)
        // News: the meme story and the PCWorld article; the thread attached to the meme story is that story's.
        #expect(counts == [.all: 6, .news: 2, .discussions: 2, .videos: 2, .episodes: 0])
        #expect(try await rows(db, t, .all).count == 6)
        for f in TopicContentFilter.allCases { #expect(try await rows(db, t, f).count == counts[f]) }
        #expect(TopicContentFilter.allCases.map(\.title) == ["All", "News", "Discussions", "Videos", "Episodes"])
    }

    @Test func unreadCountsAndMarkAllAsReadCountStoriesOnce() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26),
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 25),
            thread(2, "The internet used to be fun, Firefox reunites memes", url: "https://example.org/fun", points: 4, comments: 1, hoursAgo: 25),
            article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 8), video("v1", "Firefox video", hoursAgo: 5)])
        try await group(db, t)
        // Three articles and a thread in one story, plus an article and a video: three unread rows.
        #expect(try await db.unreadCounts()[t.id] == 3)

        // Opening the story's row reads its lead, which reads the story.
        let list = try await rows(db, t)
        let story = try #require(list.first { $0.item.guid == "khou" })
        try await db.recordOpen(HistoryEntry(item: story), isMedia: false)
        #expect(try await db.unreadCounts()[t.id] == 2)

        // Mark All as Read reads every article behind the rows too, and the thread.
        #expect(try await db.markAllRead(ItemQuery(sourceId: t.id)) == 5)
        #expect(try await db.unreadCounts()[t.id] == nil)
        let history = try await db.history()
        for guid in ["khou", "yahoo1", "yahoo2", "hn:2", "pcworld", "yt:v1"] {
            #expect(history.contains { $0.itemGuid == guid && $0.readAt != nil }, "\(guid)")
        }
    }

    @Test func aStoryNotifiesOncePerStoryAndAJoiningOutletNeverDoes() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        let search = ScriptedSearch([
            [recent("khou", Headline.khou, "KHOU", hoursAgo: 3), recent("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 2.5),
             recent("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 2)],
            [recent("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 1),
             recentThread(9, "The internet used to be fun, Firefox reunites memes", url: "https://example.org/fun", points: 6, comments: 2, hoursAgo: 1),
             recentThread(10, "Firefox gets a very different thing", url: "https://example.org/other", points: 6, comments: 2, hoursAgo: 1)],
        ])
        let svc = service(db, search)
        try await db.setSourceNotify(id: t.id, on: true)
        _ = try await svc.refreshSource(id: t.id)
        let first = try await db.takeNewPostAlerts()
        // One for the two-outlet story (its lead, the first stored) and one for the lone article.
        #expect(first.map(\.title).sorted() == [Headline.khou, Headline.pcWorld].sorted())

        _ = try await svc.refreshSource(id: t.id)
        let second = try await db.takeNewPostAlerts()
        // The new outlet joined the story and the thread attached to it: only the unattached thread is a new post.
        #expect(second.map(\.title) == ["Firefox gets a very different thing"])
        #expect(try await db.unreadCounts()[t.id] == 3)
    }

    @Test func removingALeadHandsTheStoryToItsNextArticle() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26),
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 25),
            thread(2, "The internet used to be fun, Firefox reunites memes", url: "https://example.org/fun", points: 4, comments: 1, hoursAgo: 20)])
        try await group(db, t)
        let lead = try #require(try allItems(db, t).first { $0.guid == "khou" })
        #expect(try await rows(db, t).count == 1)

        // Retention drops the lead (it is the oldest).
        let pruned = try await db.pruneOldItems(before: storyBase.addingTimeInterval(-28 * 3600))
        #expect(pruned == 1)
        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["yahoo2"])
        #expect(list[0].story?.outlets.map(\.id).first == list[0].item.id)
        #expect(list[0].story?.outlets.count == 2 && list[0].story?.discussion?.points == 4)
        #expect(list[0].item.id != lead.id)
        #expect(list[0].item.storyAt == storyBase.addingTimeInterval(-25 * 3600))

        // And the last article of a story leaves its thread a row of its own.
        _ = try await db.pruneOldItems(before: storyBase.addingTimeInterval(-25.5 * 3600))
        let one = try await rows(db, t)
        #expect(one.map(\.item.guid) == ["yahoo1"] && one[0].story?.outlets.count == 1 && one[0].story?.discussion?.points == 4)
        _ = try await db.pruneOldItems(before: storyBase.addingTimeInterval(-24.5 * 3600))
        #expect(try await rows(db, t).map(\.item.guid) == ["hn:2"])
        #expect(try await rows(db, t)[0].story == nil)
        #expect(try allItems(db, t).allSatisfy { $0.storyId == nil && $0.storyAt == nil })
    }

    @Test func aReadStayReadWhenItsLeadIsPruned() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26),
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 25), article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 8)])
        try await group(db, t)
        #expect(try await db.unreadCounts()[t.id] == 2)
        let story = try #require(try await rows(db, t).first { $0.item.guid == "khou" })
        try await db.recordOpen(HistoryEntry(item: story), isMedia: false)
        #expect(try await db.unreadCounts()[t.id] == 1)

        // The lead is pruned: the story's next article is the lead now, and the story is still read.
        #expect(try await db.pruneOldItems(before: storyBase.addingTimeInterval(-28 * 3600)) == 1)
        let list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["pcworld", "yahoo2"])
        #expect(try await db.unreadCounts()[t.id] == 1)
        let history = try await db.history()
        #expect(history.contains { $0.itemGuid == "yahoo2" && $0.readAt != nil })
        // The stale rule path does the same: removing a read lead by a stricter keyword rule keeps the story read.
        try await db.writer.write { d in
            let source = try #require(try Source.fetchOne(d, key: t.id))
            try d.execute(sql: "UPDATE items SET title = 'Nothing about it' WHERE guid = 'yahoo2'")
            #expect(try Queries.removeStaleTopicItems(d, topic: source, languages: nil) == 1)
        }
        #expect(try await rows(db, t).map(\.item.guid) == ["pcworld", "yahoo1"])
        #expect(try await db.unreadCounts()[t.id] == 1)
        #expect(try await db.history().contains { $0.itemGuid == "yahoo1" && $0.readAt != nil })
    }

    @Test func aStoryUnreadStaysUnreadWhenItsLeadIsPruned() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26)])
        try await group(db, t)
        _ = try await db.pruneOldItems(before: storyBase.addingTimeInterval(-28 * 3600))
        #expect(try await db.unreadCounts()[t.id] == 1)
    }

    @Test func aStoryTimeFollowsItsNewestArticleWhenThatIsRemoved() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 30), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 26),
            article("yahoo1", Headline.yahooVideo, "Yahoo", hoursAgo: 2)])
        try await group(db, t)
        #expect(try await rows(db, t)[0].item.storyAt == storyBase.addingTimeInterval(-2 * 3600))
        // The newest member goes (not the lead, so nothing is orphaned).
        try await db.writer.write { d in
            try d.execute(sql: "DELETE FROM items WHERE guid = 'yahoo1'")
            try Queries.repairStories(d)
        }
        #expect(try await rows(db, t)[0].item.storyAt == storyBase.addingTimeInterval(-26 * 3600))
        try await db.writer.write { d in
            try d.execute(sql: "DELETE FROM items WHERE guid = 'yahoo2'")
            try Queries.repairStories(d)
        }
        #expect(try await rows(db, t)[0].item.storyAt == nil)
    }

    @Test func savedPagesByTheItemsOwnTimeNotItsStoryTime() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, [
            article("khou", Headline.khou, "KHOU", hoursAgo: 40), article("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 2),
            article("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 20), article("lone", "Firefox gets a quiet new settings page", "Ghacks", hoursAgo: 30)])
        try await group(db, t)
        for item in try allItems(db, t) { _ = try await db.setSaved(itemId: item.id, saved: true) }
        let lead = try #require(try allItems(db, t).first { $0.guid == "khou" })
        #expect(lead.storyAt != nil)
        var paged: [String] = []
        var q = ItemQuery(view: .saved, limit: 1)
        while true {
            let page = try await db.items(q)
            paged += page.items.map(\.item.guid)
            guard let next = page.nextCursor else { break }
            q = q.after(next)
        }
        // Saved lists every saved item by its own time, story members included.
        #expect(paged == ["yahoo2", "pcworld", "lone", "khou"])
    }

    @Test func theMigrationAddsTheStoryColumnsToExistingItems() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try AppDatabase.migrator.migrate(queue, upTo: "v8-topics")
        try queue.write { d in
            try d.execute(sql: "INSERT INTO sources (title, url, feed_url, kind, \"group\") VALUES ('S', 'https://s.example', 'https://s.example/feed', 'rss', 'blogs')")
            try d.execute(sql: "INSERT INTO items (source_id, guid, url, title, published_at) VALUES (1, 'a', 'https://s.example/a', 'A', ?)", arguments: [Fixture.base])
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { d in
            let item = try #require(try Item.fetchOne(d, key: 1))
            #expect(item.storyId == nil && item.storyAt == nil)
            #expect(try Row.fetchAll(d, sql: "PRAGMA table_info(items)").contains { ($0["name"] as String) == "story_id" })
        }
    }
}

// MARK: Refresh

@Suite("Topic refresh rules")
struct TopicRefreshRuleTests {
    @Test func aRefreshRenewsTheNumbersOfStoredHackerNewsStories() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        let search = ScriptedSearch([
            [recentThread(1, "Firefox 159", url: "https://firefox.com/159", points: 1, comments: 0, hoursAgo: 30),
             recentThread(2, "Firefox 160", url: "https://firefox.com/160", points: 1, comments: 0, hoursAgo: 20)],
            [],
        ], stats: ["1": TopicHackerNewsStats(points: 15, comments: 4), "2": TopicHackerNewsStats(points: 8, comments: 3), "99": TopicHackerNewsStats(points: 1, comments: 1)])
        let svc = service(db, search)
        _ = try await svc.refreshSource(id: t.id)
        // First refresh: nothing was stored to renew. Second: both are asked for, in one request.
        #expect(search.statsRequests.isEmpty)
        _ = try await svc.refreshSource(id: t.id)
        #expect(search.statsRequests.count == 1 && Set(search.statsRequests[0]) == ["1", "2"])
        let stored = try allItems(db, t)
        #expect(stored.first { $0.guid == "hn:1" }?.hnPoints == 15 && stored.first { $0.guid == "hn:1" }?.hnComments == 4)
        #expect(stored.first { $0.guid == "hn:2" }?.hnPoints == 8 && stored.first { $0.guid == "hn:2" }?.hnComments == 3)
        let rowsNow = try await rows(db, t)
        #expect(rowsNow.first { $0.item.guid == "hn:1" }?.item.hnPoints == 15)

        // A failed request keeps the old numbers; so does a thread past the window; a topic without Hacker News doesn't ask.
        search.stats = [:]
        _ = try await svc.refreshSource(id: t.id)
        #expect(try allItems(db, t).first { $0.guid == "hn:1" }?.hnPoints == 15)
        try await db.writer.write { d in try d.execute(sql: "UPDATE items SET published_at = ? WHERE guid = 'hn:1'", arguments: [Date().addingTimeInterval(-20 * 86_400)]) }
        let before = search.statsRequests.count
        _ = try await svc.refreshSource(id: t.id)
        #expect(Set(search.statsRequests[before]) == ["2"])
        _ = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "Firefox", places: TopicPlaces(hackerNews: false)))
        _ = try await svc.refreshSource(id: t.id)
        #expect(search.statsRequests.count == before + 1)
    }

    @Test func aHackerNewsStoryLinkingToAnArticleIsItsDiscussionNotADuplicate() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db)
        let search = ScriptedSearch([
            [recent("khou", Headline.khou, "KHOU", hoursAgo: 5), recent("yahoo2", Headline.yahooMemes, "Yahoo", hoursAgo: 4)],
            // Later: a thread linking to the stored article, a title that shares nothing with it.
            [recentThread(5, "Mozilla ships something", url: "https://khou.example.com/story", points: 10, comments: 4, hoursAgo: 1)],
            // The same thread again must not be stored twice.
            [recentThread(5, "Mozilla ships something", url: "https://khou.example.com/story", points: 11, comments: 4, hoursAgo: 1)],
            // And in one batch with a new article: the article stays a row of the story, the thread is its discussion.
            [recentThread(6, "Firefox 159 other", url: "https://pcworld.example.com/story", points: 50, comments: 9, hoursAgo: 1),
             recent("pcworld", Headline.pcWorld, "PCWorld", hoursAgo: 1)],
        ])
        let svc = service(db, search)
        _ = try await svc.refreshSource(id: t.id)
        _ = try await svc.refreshSource(id: t.id)
        var list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["khou"])
        #expect(list[0].story?.discussion?.points == 10 && list[0].story?.outlets.count == 2)
        _ = try await svc.refreshSource(id: t.id)
        #expect(try allItems(db, t).count == 3)
        _ = try await svc.refreshSource(id: t.id)
        list = try await rows(db, t)
        #expect(list.map(\.item.guid) == ["pcworld", "khou"])
        #expect(list[0].story?.discussion?.points == 50 && list[0].story?.outlets.count == 1)
    }

    @Test func topicItemsAreDedupedByLinkWithinTheirKind() {
        let a = recent("a", "Firefox one", "Verge", hoursAgo: 1, url: "https://x.example.com/p")
        let b = recent("b", "Firefox one again", "Wired", hoursAgo: 1, url: "https://www.x.example.com/p/")
        let h = recentThread(1, "Firefox one", url: "https://x.example.com/p", points: 3, comments: 1, hoursAgo: 1)
        let h2 = recentThread(2, "Firefox one", url: "https://x.example.com/p", points: 9, comments: 1, hoursAgo: 1)
        #expect(DefaultRefreshService.dedupeTopicItems([a, b, h, h2], stored: []).map(\.guid) == ["a", "hn:2"])
    }

    @Test func aRefreshRemovesStoredItemsTheRulesNoLongerAllow() async throws {
        let db = try Fixture.db()
        let t = try await makeTopic(db, places: TopicPlaces(reddit: true, subscriptions: false))
        let now = Date()
        let items = [
            recent("keep", "Firefox keeps a news article", "Verge", hoursAgo: 5),
            recent("no-keyword", "Harness Corp, an incremental game", "Verge", hoursAgo: 6),
            recent("foreign", "Firefox: consejo para bajar juegos sin que me hackeen", "Verge", hoursAgo: 7),
            recent("paywalled", "Firefox in a paywalled place", "The Wall Street Journal", hoursAgo: 8, url: "https://www.wsj.com/a"),
            recent("saved", "Harness Corp saved by the user", "Verge", hoursAgo: 9),
            recent("highlighted", "Harness Corp highlighted by the user", "Verge", hoursAgo: 10),
            ParsedItem(guid: "reddit:1", url: "https://www.reddit.com/r/firefox/comments/1/x/", title: "Firefox help", author: "r/firefox", publishedAt: now.addingTimeInterval(-3600)),
        ]
        try Fixture.items(db, sourceId: t.id, items)
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE items SET is_saved = 1 WHERE guid = 'saved'")
        }
        _ = try await db.insertHighlight(Highlight(
            sourceFeedUrl: t.feedUrl, itemGuid: "highlighted", itemUrl: "https://highlighted.example.com/story", itemTitle: "t", sourceTitle: t.title, text: "x"))

        // Reddit on: it stays; the rest of the rules apply.
        let svc = service(db, ScriptedSearch([[], []]))
        _ = try await svc.refreshSource(id: t.id)
        #expect(Set(try allItems(db, t).map(\.guid)) == ["keep", "saved", "highlighted", "reddit:1"])

        // Reddit turned off: its posts go on the next refresh, saved ones would stay.
        _ = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "Firefox", places: TopicPlaces(reddit: false, subscriptions: false)))
        #expect(Set(try allItems(db, t).map(\.guid)).contains("reddit:1"))
        _ = try await svc.refreshSource(id: t.id)
        #expect(Set(try allItems(db, t).map(\.guid)) == ["keep", "saved", "highlighted"])

        // Skip paywalled off: the earlier removal is not undone, and later ones are kept.
        let wsj = recent("wsj", "Firefox in a paywalled place", "The Wall Street Journal", hoursAgo: 8, url: "https://www.wsj.com/b")
        _ = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "Firefox", places: TopicPlaces(subscriptions: false), skipPaywalled: false))
        try Fixture.items(db, sourceId: t.id, [wsj])
        _ = try await service(db, ScriptedSearch([[]])).refreshSource(id: t.id)
        #expect(try allItems(db, t).contains { $0.guid == "wsj" })
    }

    @Test func theRealFirefoxTopicIsCleanedAtItsNextRefresh() async throws {
        // The 61 items the first version stored for "Firefox" (Oct 18 - 29 2026): a Reddit place that wasn't asked for, Hacker News
        // stories that matched through their link or body, a Greek and a Russian title.
        let url = try #require(Bundle.module.url(forResource: "firefox-items", withExtension: "json", subdirectory: "Topics"))
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let parsed = stored.map { r in
            ParsedItem(guid: r["guid"] as! String, url: r["url"] as! String, title: r["title"] as! String, author: r["author"] as? String,
                       publishedAt: ISO8601.date(from: r["published_at"] as! String)!, videoId: r["video_id"] as? String,
                       audioUrl: r["audio_url"] as? String, hnPoints: r["hn_points"] as? Int, hnComments: r["hn_comments"] as? Int,
                       hnCommentsUrl: r["hn_comments_url"] as? String)
        }
        #expect(parsed.count == 61)

        let db = try Fixture.db()
        let t = try await makeTopic(db)
        try Fixture.items(db, sourceId: t.id, parsed)
        let removed = try await db.writer.write { d in
            try Queries.removeStaleTopicItems(d, topic: try #require(try Source.fetchOne(d, key: t.id)), languages: TopicFixtures.english)
        }
        let kept = try allItems(db, t)
        // 12 Reddit posts, 8 Hacker News stories with no keyword in the title (they matched through their link or text), 1 Russian title.
        #expect(removed == 21 && kept.count == 40)
        #expect(!kept.contains { $0.guid.hasPrefix("reddit:") })
        #expect(kept.filter { $0.guid.hasPrefix("hn:") }.count == 20)
        #expect(kept.allSatisfy { $0.title.localizedCaseInsensitiveContains("firefox") })
        #expect(!kept.contains { $0.title.hasPrefix("549.") })

        try await group(db, t)
        let list = try await rows(db, t)
        // The twelve news articles are seven rows: the meme ad (three outlets), Smart Window (three) and Firefox 159's security
        // fixes (note and PCWorld) are one each.
        #expect(list.count == 35)
        let stories = list.compactMap(\.story)
        #expect(stories.map { $0.outlets.count }.sorted() == [2, 3, 3])
        #expect(Set(stories.flatMap { $0.outlets.map(\.name) }) == ["Yahoo", "KHOU", "BetaNews", "9to5Mac", "The Verge", "note", "PCWorld"])
        let counts = try await db.topicFilterCounts(topicId: t.id)
        #expect(counts == [.all: 35, .news: 7, .discussions: 20, .videos: 5, .episodes: 3])
        #expect(try await db.unreadCounts()[t.id] == 35)

    }
}
