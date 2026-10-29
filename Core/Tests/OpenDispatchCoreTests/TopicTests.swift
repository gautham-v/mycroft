import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

/// Saved answers in Fixtures/Topics, all from the live endpoints a topic searches except where noted:
/// - bing-news.xml: Bing News RSS (`format=rss`), four real items, plus one hand-made New York Times item for the paywall skip.
/// - hn-search.json: Algolia's `search_by_date` for "openai", trimmed to four stories (one is an Ask HN with no link). Two titles
///   were given an "OpenAI: " prefix by hand, as the keyword has to be in the title.
/// - reddit-search.rss: Reddit's search RSS, one matching subreddit (`t5_`) and three posts. Reddit refuses the JSON to the
///   machine these were saved on, so reddit-search.json is written by hand in the documented listing shape.
/// - youtube-recent.json: innertube search results trimmed to seven videos (one with its upload time removed by hand).
/// - itunes-recent.json: iTunes episode search for "vision pro", trimmed to five episodes.
enum TopicFixtures {
    static func data(_ name: String, _ ext: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Topics"),
              let data = try? Data(contentsOf: url) else { fatalError("missing fixture \(name).\(ext)") }
        return data
    }

    static var bing: Data { data("bing-news", "xml") }
    static var hn: Data { data("hn-search", "json") }
    static var redditJSON: Data { data("reddit-search", "json") }
    static var redditRSS: Data { data("reddit-search", "rss") }
    static var youtube: Data { data("youtube-recent", "json") }
    static var itunes: Data { data("itunes-recent", "json") }

    /// The reader the fixtures are searched for: English, in the US.
    static let english = TopicLanguages(preferred: ["en-US"], region: "US")

    /// The moment the fixtures were read at.
    static let now = ISO8601.date(from: "2026-10-29T03:00:00Z")!

    /// A fake network: answers by URL fragment, records what was asked.
    final class Network: @unchecked Sendable {
        struct Route { var fragment: String; var status: Int; var body: Data }
        struct Request { var url: String; var headers: [String: String]; var body: Data? }
        private let lock = NSLock()
        private var routes: [Route]
        private var asked: [Request] = []
        /// URL fragments that fail with a transport error instead of answering.
        private var failing: [String]

        init(_ routes: [Route], failing: [String] = []) {
            self.routes = routes
            self.failing = failing
        }

        convenience init(news: Data? = TopicFixtures.bing, hn: Data? = TopicFixtures.hn, reddit: Data? = TopicFixtures.redditRSS,
                         youtube: Data? = TopicFixtures.youtube, itunes: Data? = TopicFixtures.itunes,
                         bluesky: Data? = DiscussionFixtures.data("bluesky-search.json"), redditJSONStatus: Int = 403) {
            var routes: [Route] = []
            if let news { routes.append(Route(fragment: "bing.com/news", status: 200, body: news)) }
            if let hn { routes.append(Route(fragment: "hn.algolia.com", status: 200, body: hn)) }
            routes.append(Route(fragment: "reddit.com/search.json", status: redditJSONStatus, body: TopicFixtures.redditJSON))
            if let reddit { routes.append(Route(fragment: "reddit.com/search.rss", status: 200, body: reddit)) }
            if let youtube { routes.append(Route(fragment: "youtube.com/youtubei", status: 200, body: youtube)) }
            if let itunes { routes.append(Route(fragment: "itunes.apple.com", status: 200, body: itunes)) }
            if let bluesky { routes.append(Route(fragment: "api.bsky.app", status: 200, body: bluesky)) }
            self.init(routes)
        }

        var requests: [Request] { lock.lock(); defer { lock.unlock() }; return asked }
        func requests(containing fragment: String) -> [Request] { requests.filter { $0.url.contains(fragment) } }

        func answer(_ url: String, headers: [String: String], body: Data?) throws -> (Data, HTTPURLResponse) {
            lock.lock()
            asked.append(Request(url: url, headers: headers, body: body))
            let route = routes.first { url.contains($0.fragment) }
            let fails = failing.contains { url.contains($0) }
            lock.unlock()
            if fails { throw URLError(.notConnectedToInternet) }
            let status = route?.status ?? 404
            return (route?.body ?? Data(), HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        func search() -> DefaultTopicSearch {
            let explore = DefaultExploreSearch(fetch: { url, body in try self.answer(url, headers: [:], body: body) }, language: "de", region: "US")
            return DefaultTopicSearch(fetch: { url, headers in try self.answer(url, headers: headers, body: nil) }, explore: explore, languages: TopicFixtures.english)
        }
    }
}

@Suite("Topic options and matching")
struct TopicOptionsTests {
    @Test func optionsRoundTripAsDeterministicJSON() throws {
        let o = TopicOptions(
            keyword: "Vision Pro", excluded: ["rumor", "case"], notableOnly: true,
            places: TopicPlaces(news: false, hackerNews: true, x: false, bluesky: false, media: false, subscriptions: true), skipPaywalled: false)
        let json = o.json
        #expect(TopicOptions(json: json) == o)
        // Sorted keys, so two devices produce the same text for the same options.
        #expect(json.hasPrefix("{\"excluded\":[\"rumor\",\"case\"],\"keyword\":\"Vision Pro\",\"notableOnly\":true,\"places\":{"))
        #expect(TopicOptions(json: nil) == nil)
        #expect(TopicOptions(json: "not json") == nil)
    }

    @Test func missingKeysReadAsDefaults() throws {
        let o = try #require(TopicOptions(json: #"{"keyword":"rust"}"#))
        #expect(o == TopicOptions(keyword: "rust"))
        #expect(o.places == .defaults && !o.places.reddit && !o.notableOnly && o.skipPaywalled && o.excluded.isEmpty)
        let partial = try #require(TopicOptions(json: #"{"keyword":"rust","places":{"news":false}}"#))
        #expect(partial.places == TopicPlaces(news: false))
    }

    @Test func cleanedTrimsAndDropsRepeats() {
        let o = TopicOptions(keyword: "  vision   pro ", excluded: [" Rumor ", "", "rumor", "case"]).cleaned
        #expect(o.keyword == "vision pro")
        #expect(o.excluded == ["Rumor", "case"])
        #expect(TopicOptions.excludedWords(from: " a, b ,, c ") == ["a", "b", "c"])
        #expect(o.excludedText == "Rumor, case")
        #expect(TopicPlaces(news: false, hackerNews: true, media: true, subscriptions: true).searched == [.hackerNews, .x, .bluesky, .media])
        #expect(TopicPlaces(news: false, hackerNews: false, x: false, bluesky: false, media: false, subscriptions: true).searched.isEmpty)
    }

    @Test func matcherIgnoresCaseAndDiacritics() {
        let m = TopicMatcher(keyword: "café")
        #expect(m.matches(title: "A CAFE opens", summary: nil))
        #expect(m.matches(title: "Nothing", summary: "<p>The Café scene</p>"))
        #expect(!m.matches(title: "Nothing", summary: "Coffee"))
    }

    @Test func multiWordKeywordNeedsEveryWord() {
        let m = TopicMatcher(keyword: "\"vision pro\"")
        #expect(m.matches(title: "Apple Vision headset, the Pro model", summary: nil))
        // Words may be split between the title and the summary.
        #expect(m.matches(title: "Vision news", summary: "<b>Pro</b> users"))
        #expect(!m.matches(title: "Vision news", summary: "Nothing else"))
    }

    @Test func wordsMatchAtWordStartsAndShortOnesWhole() {
        #expect(TopicMatcher(keyword: "agent").matches(title: "AI agents everywhere", summary: nil))
        #expect(!TopicMatcher(keyword: "agent").matches(title: "A reagent", summary: nil))
        #expect(TopicMatcher(keyword: "AI").matches(title: "AI, again", summary: nil))
        #expect(!TopicMatcher(keyword: "AI").matches(title: "He said so", summary: nil))
        #expect(TopicMatcher(keyword: "C++").matches(title: "Learning C++ today", summary: nil))
        #expect(!TopicMatcher(keyword: "").matches(title: "anything", summary: nil))
    }

    @Test func excludedWordsDropAMatchInTitleOrSummary() {
        let m = TopicMatcher(keyword: "vision pro", excluded: ["Rumor", "Giveaway"])
        #expect(m.matches(title: "Vision Pro review", summary: nil))
        #expect(!m.matches(title: "Vision Pro rumor roundup", summary: nil))
        #expect(!m.matches(title: "Vision Pro review", summary: "<p>Enter the GIVEAWAY</p>"))
    }

    @Test func sqlFunctionAgreesWithTheMatcher() async throws {
        let db = try Fixture.db()
        let hit = try await db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT opendispatch_topic_matches(?, ?, ?, ?)", arguments: ["Vision Pro news", "x", "vision pro", "rumor\ncase"])
        }
        #expect(hit == true)
        let miss = try await db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT opendispatch_topic_matches(?, ?, ?, ?)", arguments: ["Vision Pro news", "a rumor", "vision pro", "rumor\ncase"])
        }
        #expect(miss == false)
    }

    @Test func paywallsMatchHostSuffixAndPublisherNames() {
        #expect(TopicPaywalls.isPaywalled("https://www.nytimes.com/2026/10/28/a.html"))
        #expect(TopicPaywalls.isPaywalled("https://cooking.nytimes.com/recipes/1"))
        #expect(TopicPaywalls.isPaywalled("https://wsj.com/a"))
        #expect(TopicPaywalls.isPaywalled("https://www.thetimes.co.uk/article/x"))
        #expect(!TopicPaywalls.isPaywalled("https://notnytimes.com/a"))
        #expect(!TopicPaywalls.isPaywalled("https://www.macrumors.com/a"))
        #expect(TopicPaywalls.isPaywalled(publisher: "Barron's on MSN"))
        #expect(TopicPaywalls.isPaywalled(publisher: "Barron\u{2019}s"))
        #expect(TopicPaywalls.isPaywalled(publisher: "The Wall Street Journal"))
        #expect(TopicPaywalls.isPaywalled(publisher: "Bloomberg.com"))
        #expect(!TopicPaywalls.isPaywalled(publisher: "CBS News"))
    }

    @Test func contentFilterCategoriesAreExclusive() {
        func item(_ f: (inout Item) -> Void) -> Item {
            var i = Item(sourceId: 1, guid: "g", url: "https://example.com/a", title: "t", publishedAt: Fixture.base)
            f(&i)
            return i
        }
        #expect(TopicContentFilter.category(of: item { _ in }) == .news)
        #expect(TopicContentFilter.category(of: item { $0.videoId = "abc" }) == .videos)
        #expect(TopicContentFilter.category(of: item { $0.audioUrl = "https://x/a.mp3" }) == .episodes)
        #expect(TopicContentFilter.category(of: item { $0.hnCommentsUrl = "https://news.ycombinator.com/item?id=1" }) == .discussions)
        #expect(TopicContentFilter.category(of: item { $0.url = "https://www.reddit.com/r/apple/comments/1/x/" }) == .discussions)
    }
}

@Suite("Topic providers")
struct TopicProviderTests {
    private let now = TopicFixtures.now

    @Test func bingLinksAreDecodedToThePublisherURL() throws {
        let link = "http://www.bing.com/news/apiclick.aspx?ref=FexRss&aid=&tid=6ae2&url=https%3a%2f%2fwww.macrumors.com%2f2026%2f09%2f28%2fvision-pro%2f&c=1&mkt=en-us"
        #expect(DefaultTopicSearch.articleURL(fromBingLink: link) == "https://www.macrumors.com/2026/09/28/vision-pro/")
        #expect(DefaultTopicSearch.articleURL(fromBingLink: "http://www.bing.com/news/apiclick.aspx?ref=x") == nil)
        #expect(DefaultTopicSearch.articleURL(fromBingLink: "https://example.com/a") == "https://example.com/a")
        #expect(DefaultTopicSearch.articleURL(fromBingLink: "ftp://example.com/a") == nil)

        let found = try DefaultTopicSearch.parseNews(TopicFixtures.bing)
        #expect(found.count == 5)
        let first = found[0].item
        #expect(first.url == "https://www.cbsnews.com/news/iphone-duo-owners-report-cracked-screens-apple-foldable/")
        #expect(first.author == "CBS News")
        #expect(first.guid == first.url)
        #expect(first.summary?.isEmpty == false)
        #expect(found[0].host == "cbsnews.com")
        #expect(found[4].item.url.hasPrefix("https://www.nytimes.com/"))
    }

    @Test func newsRequestIsAQuotedPhraseSortedByDate() async throws {
        let net = TopicFixtures.Network()
        _ = await net.search().search(
            TopicOptions(keyword: "iPhone Duo", places: TopicPlaces(news: true, hackerNews: false, x: false, bluesky: false, media: false, subscriptions: false)),
            subscriptions: .empty, now: now)
        let url = try #require(net.requests(containing: "bing.com").first?.url)
        #expect(url == "https://www.bing.com/news/search?q=%22iPhone%20Duo%22&format=rss&qft=sortbydate%3d%221%22&mkt=en-US&setlang=en-US")
        // One word is sent as it is, and with no market Bing chooses.
        #expect(DefaultTopicSearch.newsURL("rust").contains("q=rust&"))
        #expect(!DefaultTopicSearch.newsURL("rust").contains("mkt="))
    }

    @Test func newsKeepsOnTopicArticlesFromPaywalledSitesToo() async throws {
        let net = TopicFixtures.Network()
        let places = TopicPlaces(news: true, hackerNews: false, x: false, bluesky: false, media: false, subscriptions: false)
        // CBS, the New York Times, IGN; the Investor's and Barron's items don't mention it. The lists mark or hide the paywalled one.
        for skip in [true, false] {
            let found = await net.search().search(TopicOptions(keyword: "iPhone Duo", places: places, skipPaywalled: skip), subscriptions: .empty, now: now)
            #expect(found.items.map { $0.author } == ["CBS News", "The New York Times", "IGN"])
            #expect(found.failures.isEmpty)
            // An aggregator's address hides the site; the publisher's name gave it away, and it is kept as well.
            let tesla = await net.search().search(TopicOptions(keyword: "tesla", places: places, skipPaywalled: skip), subscriptions: .empty, now: now)
            #expect(tesla.items.map { $0.author } == ["Barron's on MSN", "Investor's Business Daily"])
        }
    }

    @Test func hackerNewsStoriesCarryPointsAndTheirDiscussion() throws {
        let found = try DefaultTopicSearch.parseHackerNews(TopicFixtures.hn)
        #expect(found.count == 4)
        let story = found[0].item
        #expect(story.guid == "hn:50251344")
        #expect(story.url == "https://openai.com/index/building-scientific-understanding-with-academic-communities/")
        #expect(story.hnPoints == 1149 && story.hnComments == 693)
        #expect(story.hnCommentsUrl == "https://news.ycombinator.com/item?id=50251344")
        #expect(story.author == "Hacker News")
        // An Ask HN has no link: it links to its own page, and its text is the summary.
        let ask = found[1].item
        #expect(ask.url == "https://news.ycombinator.com/item?id=50200997")
        #expect(ask.summary?.contains("frontier models") == true)
    }

    @Test func hackerNewsRequestAsksForTheRetentionWindowAndNotablePoints() throws {
        let url = DefaultTopicSearch.hackerNewsURL("vision pro", notableOnly: false, now: now)
        let since = Int(Retention.cutoff(now: now).timeIntervalSince1970)
        #expect(url == "https://hn.algolia.com/api/v1/search_by_date?query=%22vision%20pro%22&tags=story&hitsPerPage=50&numericFilters=created_at_i%3E\(since)")
        #expect(DefaultTopicSearch.hackerNewsURL("rust", notableOnly: true, now: now).hasSuffix("created_at_i%3E\(since),points%3E=100"))
    }

    @Test func redditJSONCarriesScoreAndSkipsAdultPosts() throws {
        let found = try DefaultTopicSearch.parseRedditJSON(TopicFixtures.redditJSON)
        #expect(found.map(\.item.guid) == ["reddit:1xhb0k2", "reddit:1xhmq77"])
        let post = found[0].item
        #expect(post.url == "https://www.reddit.com/r/VisionPro/comments/1xhb0k2/apple_vision_pro_m5_one_year_later/")
        #expect(post.author == "r/VisionPro")
        #expect(post.hnPoints == 412 && post.hnComments == 87)
        #expect(post.hnCommentsUrl == nil)
        #expect(post.thumbnailUrl == "https://b.thumbs.redditmedia.com/example-a.jpg")
        #expect(found[1].item.thumbnailUrl == nil)
        #expect(found[1].item.summary == nil)
    }

    @Test func redditRSSKeepsPostsAndLeavesSubredditsOut() throws {
        let found = try DefaultTopicSearch.parseRedditRSS(TopicFixtures.redditRSS)
        #expect(found.count == 3)
        let post = found[0].item
        #expect(post.guid == "reddit:1xi84d5")
        #expect(post.title == "Audio Bluetooth Bug in Mac Virtual Display?")
        #expect(post.url == "https://www.reddit.com/r/VisionPro/comments/1xi84d5/audio_bluetooth_bug_in_mac_virtual_display/")
        #expect(post.author == "r/VisionPro")
        #expect(post.summary?.hasPrefix("For as long as I remember") == true)
        #expect(post.summary?.contains("submitted by") == false)
        #expect(post.hnPoints == nil)
        #expect(found[0].score == nil)
    }

    @Test func redditFallsBackToRSSWhenTheJSONIsRefused() async throws {
        let net = TopicFixtures.Network(redditJSONStatus: 403)
        let places = TopicPlaces(news: false, hackerNews: false, reddit: true, x: false, bluesky: false, media: false, subscriptions: false)
        let out = await net.search().search(TopicOptions(keyword: "vision pro", places: places), subscriptions: .empty, now: now)
        let json = try #require(net.requests(containing: "reddit.com/search.json").first)
        #expect(json.url.hasPrefix("https://www.reddit.com/search.json?q=%22vision%20pro%22&sort=new&t=week"))
        #expect(json.headers["User-Agent"]?.hasPrefix("macOS:") == true)
        #expect(net.requests(containing: "reddit.com/search.rss").count == 1)
        #expect(out.items.contains { $0.guid == "reddit:1xi7yd6" })

        // When the JSON works, the RSS isn't asked for.
        let net2 = TopicFixtures.Network(redditJSONStatus: 200)
        let out2 = await net2.search().search(TopicOptions(keyword: "vision pro", places: places), subscriptions: .empty, now: now)
        #expect(net2.requests(containing: "reddit.com/search.rss").isEmpty)
        #expect(out2.items.contains { $0.guid == "reddit:1xhb0k2" && $0.hnPoints == 412 })
    }

    @Test func relativeUploadTimesBecomeDates() {
        let n = now
        #expect(DefaultTopicSearch.publishedDate(relative: "7 hours ago", now: n) == n.addingTimeInterval(-7 * 3600))
        #expect(DefaultTopicSearch.publishedDate(relative: "1 day ago", now: n) == n.addingTimeInterval(-86_400))
        #expect(DefaultTopicSearch.publishedDate(relative: "Streamed 3 days ago", now: n) == n.addingTimeInterval(-3 * 86_400))
        #expect(DefaultTopicSearch.publishedDate(relative: "2 weeks ago", now: n) == n.addingTimeInterval(-14 * 86_400))
        #expect(DefaultTopicSearch.publishedDate(relative: "5 minutes ago", now: n) == n.addingTimeInterval(-300))
        #expect(DefaultTopicSearch.publishedDate(relative: "1 month ago", now: n) == n.addingTimeInterval(-30 * 86_400))
        #expect(DefaultTopicSearch.publishedDate(relative: "vor 3 Stunden", now: n) == nil)
        #expect(DefaultTopicSearch.publishedDate(relative: "", now: n) == nil)
    }

    @Test func videosAreItemsLikeAChannelsOwn() async throws {
        let explore = DefaultExploreSearch(fetch: { url, _ in
            (TopicFixtures.youtube, HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, language: "de", region: "US")
        let results = try await explore.recentVideos("vision pro")
        let found = DefaultTopicSearch.candidates(videos: results.videos, now: now)
        // The video with no upload time can't be placed in the retention window and is left out.
        #expect(found.count == 6)
        let first = found[0].item
        #expect(first.guid == "yt:8nZiR-vXAfw")
        #expect(first.url == "https://www.youtube.com/watch?v=8nZiR-vXAfw")
        #expect(first.videoId == "8nZiR-vXAfw")
        #expect(first.author == "The Bald Coder")
        #expect(first.publishedAt == now.addingTimeInterval(-7 * 3600))
        #expect(first.durationSec == 15 * 60 + 8)
        #expect(first.thumbnailUrl == "https://i.ytimg.com/vi/8nZiR-vXAfw/hqdefault.jpg")
        #expect(found[0].channelID == "UCE3Q1BsHrW6FK4aSUdO32bQ")
    }

    @Test func recentVideoSearchAsksForUploadOrderInEnglish() async throws {
        let net = TopicFixtures.Network()
        let places = TopicPlaces(news: false, hackerNews: false, x: false, bluesky: false, media: true, subscriptions: false)
        let out = await net.search().search(TopicOptions(keyword: "vision pro", places: places), subscriptions: .empty, now: now)
        let request = try #require(net.requests(containing: "youtubei").first)
        let sent = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["params"] as? String == "CAISAggE")
        #expect(body["query"] as? String == "\"vision pro\"")
        let client = ((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client?["hl"] as? String == "en")
        // Titles naming the keyword, within the last 14 days only: 7 hours, 4 days, 13 days and exactly 2 weeks. "Apple Should
        // Be Embarrassed" (7 days) doesn't name it; the 2 months one is too old.
        let videos = out.items.filter { $0.videoId != nil }
        #expect(videos.map { $0.videoId } == ["8nZiR-vXAfw", "VzQNCA2DYyc", "jmKs28irSOE", "ulkyM5HxmOQ"])
    }

    @Test func episodesAreStoredAsTheirAppleLinkWould() async throws {
        let explore = DefaultExploreSearch(fetch: { url, _ in
            (TopicFixtures.itunes, HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, language: "en", region: "US")
        let episodes = try await explore.recentEpisodes("vision pro")
        let found = DefaultTopicSearch.candidates(episodes: episodes, now: now)
        #expect(found.count == 5)
        let first = found[0].item
        let hit = try #require(episodes.first)
        // What opening the Explore episode stores, so the same player and show-notes lookup apply.
        #expect(first == ApplePodcastEpisode.item(explore: hit, now: now))
        #expect(first.guid == hit.appleUrl)
        #expect(first.audioUrl != nil && first.thumbnailUrl != nil)
        #expect(first.author == "Vision ProFiles")
        #expect(found[0].name == "Vision ProFiles")
    }

    @Test func podcastSearchKeepsTheLastFortnight() async throws {
        let net = TopicFixtures.Network()
        let places = TopicPlaces(news: false, hackerNews: false, x: false, bluesky: false, media: true, subscriptions: false)
        let out = await net.search().search(TopicOptions(keyword: "vision pro", places: places), subscriptions: .empty, now: now)
        let ask = try #require(net.requests(containing: "itunes.apple.com").first)
        #expect(ask.url.contains("limit=200"))
        let episodes = out.items.filter { $0.audioUrl != nil }
        // Oct 27 and Oct 20 (the Oct 13, Oct 1 and 2024 ones are past the window), and only those that name the keyword.
        #expect(episodes.allSatisfy { $0.publishedAt >= Retention.cutoff(now: now) })
        #expect(episodes.contains { $0.title == "Vision Pro M5, One Year Later" })
        #expect(!episodes.contains { $0.title == "Your Quest Library Comes to Vision Pro" })
    }

    @Test func notableRuleIsPointsScoreOrFollowedOrigin() throws {
        let subs = TopicSubscriptions(sources: [
            Source(title: "The Verge", url: "https://www.theverge.com", feedUrl: "https://www.theverge.com/rss", kind: .rss, group: "news"),
            Source(title: "Fireship", url: "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA",
                   feedUrl: FeedDetection.youtubeFeedURL(channelID: "UCsBjURrPoezykLs9EqgamOA"), kind: .youtube, group: "youtube"),
            Source(title: "Hard Fork", url: "https://example.org", feedUrl: "https://example.org/feed", kind: .podcast, group: "podcast"),
            Source(title: "Hacker News", url: "https://news.ycombinator.com", feedUrl: "https://hnrss.org/newest", kind: .rss, group: "aggregator"),
        ])
        func c(_ f: (inout DefaultTopicSearch.Candidate) -> Void) -> DefaultTopicSearch.Candidate {
            var cand = DefaultTopicSearch.Candidate(item: ParsedItem(guid: "g", url: "https://x.example/a", title: "t", publishedAt: now))
            f(&cand)
            return cand
        }
        #expect(c { $0.score = 100; $0.scoreBar = TopicNotability.hackerNewsPoints }.isNotable(subs))
        #expect(!c { $0.score = 99; $0.scoreBar = TopicNotability.hackerNewsPoints }.isNotable(subs))
        #expect(c { $0.score = 200; $0.scoreBar = TopicNotability.redditScore }.isNotable(subs))
        #expect(!c { $0.score = 199; $0.scoreBar = TopicNotability.redditScore }.isNotable(subs))
        #expect(!c { $0.score = nil; $0.scoreBar = TopicNotability.redditScore }.isNotable(subs))
        // A site, channel or show the user follows, by host (also a subdomain), channel id or name.
        #expect(c { $0.host = "theverge.com" }.isNotable(subs))
        #expect(c { $0.host = "www.theverge.com" }.isNotable(subs))
        #expect(c { $0.host = "tech.theverge.com" }.isNotable(subs))
        #expect(!c { $0.host = "example.com" }.isNotable(subs))
        #expect(c { $0.channelID = "UCsBjURrPoezykLs9EqgamOA" }.isNotable(subs))
        #expect(c { $0.name = "fireship" }.isNotable(subs))
        #expect(c { $0.name = "Hard Fork" }.isNotable(subs))
        #expect(!c { $0.name = "Other Show" }.isNotable(subs))
        // Following a platform's channel or aggregator isn't following the platform.
        #expect(!c { $0.host = "youtube.com" }.isNotable(subs))
        #expect(!c { $0.host = "news.ycombinator.com" }.isNotable(subs))
    }

    @Test func notableOnlyKeepsHighPointsAndFollowedOrigins() async throws {
        let net = TopicFixtures.Network()
        let discussions = TopicPlaces(news: false, hackerNews: true, reddit: true, x: false, bluesky: false, media: false, subscriptions: false)
        let everything = await net.search().search(TopicOptions(keyword: "openai", places: discussions), subscriptions: .empty, now: now)
        #expect(everything.items.filter { $0.guid.hasPrefix("hn:") }.count == 4)
        let notable = await net.search().search(TopicOptions(keyword: "openai", notableOnly: true, places: discussions), subscriptions: .empty, now: now)
        // 1149, 680 and 126 points; not the one with 1.
        #expect(Set(notable.items.filter { $0.guid.hasPrefix("hn:") }.compactMap { $0.hnPoints }) == [1149, 680, 126])
        #expect(notable.items.allSatisfy { !$0.guid.hasPrefix("reddit:") })
        let hnRequest = try #require(net.requests(containing: "hn.algolia.com").last)
        #expect(hnRequest.url.hasSuffix(",points%3E=100"))

        // The low-scoring story links to a site; following that site makes it notable.
        let low = try #require(try DefaultTopicSearch.parseHackerNews(TopicFixtures.hn).first { $0.item.hnPoints == 1 })
        let host = try #require(low.host)
        #expect(!low.isNotable(.empty))
        let follows = TopicSubscriptions(sources: [Source(title: "Credits", url: "https://\(host)", feedUrl: "https://\(host)/feed", kind: .rss, group: "blogs")])
        #expect(low.isNotable(follows))
    }

    @Test func aFailingPlaceDoesNotFailTheOthersAndAllFailingDoes() async throws {
        let net = TopicFixtures.Network(news: nil)
        let partial = await net.search().search(TopicOptions(keyword: "iPhone Duo"), subscriptions: .empty, now: now)
        // Bing answers 404; the rest worked.
        #expect(partial.failures[.news] == "HTTP 404")
        #expect(partial.failures.count == 1)
        #expect(!partial.allFailed)
        // X isn't searched: the app isn't signed in to it.
        #expect(partial.searched == [.news, .hackerNews, .bluesky, .media])
        #expect(!partial.items.isEmpty)

        // Places fail on their own: Reddit down, Hacker News up. Media has two providers and fails only when both did.
        let redditDown = TopicFixtures.Network([
            .init(fragment: "hn.algolia.com", status: 200, body: TopicFixtures.hn),
            .init(fragment: "reddit.com", status: 500, body: Data()),
        ])
        let places = TopicPlaces(news: false, hackerNews: true, reddit: true, x: false, bluesky: false, media: false, subscriptions: false)
        let half = await redditDown.search().search(TopicOptions(keyword: "openai", places: places), subscriptions: .empty, now: now)
        #expect(Set(half.failures.keys) == [.reddit] && !half.allFailed)
        #expect(half.items.contains { $0.guid.hasPrefix("hn:") })

        let nothing = TopicFixtures.Network([], failing: ["bing.com", "algolia", "reddit.com", "youtubei", "itunes", "bsky.app"])
        let none = await nothing.search().search(TopicOptions(keyword: "openai"), subscriptions: .empty, now: now)
        #expect(none.allFailed)
        #expect(Set(none.failures.keys) == [.news, .hackerNews, .bluesky, .media])
        #expect(none.errorMessage != nil)
        #expect(none.items.isEmpty)
    }

    @Test func placesThatAreOffAreNotAsked() async throws {
        let net = TopicFixtures.Network()
        let out = await net.search().search(
            TopicOptions(keyword: "openai", places: TopicPlaces(news: false, hackerNews: true, x: false, bluesky: false, media: false, subscriptions: true)),
            subscriptions: .empty, now: now)
        #expect(out.searched == [.hackerNews])
        #expect(net.requests(containing: "bing.com").isEmpty && net.requests(containing: "youtubei").isEmpty && net.requests(containing: "itunes").isEmpty)
        let none = await net.search().search(
            TopicOptions(keyword: "openai", places: TopicPlaces(news: false, hackerNews: false, x: false, bluesky: false, media: false, subscriptions: true)),
            subscriptions: .empty, now: now)
        #expect(none.items.isEmpty && none.searched.isEmpty && !none.allFailed)
    }

    @Test func eachProviderIsCappedAtThirtyNewestFirst() {
        let candidates = (0..<45).map { i in
            DefaultTopicSearch.Candidate(item: ParsedItem(
                guid: "g\(i)", url: "https://example.com/\(i)", title: "rust \(i)", publishedAt: now.addingTimeInterval(-Double(i) * 60)))
        }
        let o = TopicOptions(keyword: "rust")
        let out = DefaultTopicSearch.finish(candidates, o, TopicMatcher(o), .empty, now)
        #expect(out.count == DefaultTopicSearch.perProviderCap)
        #expect(out.first?.guid == "g0" && out.last?.guid == "g29")
    }
}
