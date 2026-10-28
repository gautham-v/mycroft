import Foundation
import Testing
@testable import OpenDispatchCore

/// Saved answers in Fixtures/Explore: YouTube's innertube search for "fireship" and the iTunes episode search for
/// "roman empire", both trimmed to a handful of results. The YouTube one keeps a channel in each order's place, a
/// "Latest from" shelf repeating videos, a Shorts shelf, and a live stream (its length removed by hand, since a real one
/// can't be saved to order).
enum ExploreFixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Explore"),
              let data = try? Data(contentsOf: url) else { fatalError("missing fixture \(name).json") }
        return data
    }

    static var youtube: Data { data("youtube-search") }
    static var itunes: Data { data("itunes-episodes") }

    /// Answers every request with `body`, recording the URLs and POST bodies asked.
    final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(url: String, body: Data?)] = []
        let body: Data
        let status: Int
        init(_ body: Data, status: Int = 200) { self.body = body; self.status = status }
        var requests: [(url: String, body: Data?)] { lock.lock(); defer { lock.unlock() }; return asked }

        func search(language: String = "en", region: String = "US") -> DefaultExploreSearch {
            DefaultExploreSearch(fetch: { url, body in
                self.lock.lock(); self.asked.append((url, body)); self.lock.unlock()
                return (self.body, HTTPURLResponse(url: URL(string: url)!, statusCode: self.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }, language: language, region: region)
        }
    }
}

@Suite("Explore search")
struct ExploreSearchTests {
    @Test func readsVideosAndChannelsFromTheSearchAnswer() async throws {
        let net = ExploreFixtures.Network(ExploreFixtures.youtube)
        let results = try await net.search().videos("fireship")

        // Page order; the shelf's repeat of a video, the Short and the live stream (no length) are left out.
        #expect(results.videos.map(\.id) == ["nEaJMdM1djM", "G_em1hHPnXY", "SMGg7iisHmc", "zv6B6PQOuHE", "b2tjnxX8IHU"])
        let first = results.videos[0]
        #expect(first.title == "Did the AI bubble just pop?")
        #expect(first.channel == "Fireship")
        #expect(first.channelID == "UCsBjURrPoezykLs9EqgamOA")
        #expect(first.views == "946K views")
        #expect(first.published == "7 hours ago")
        #expect(first.duration == "5:25")
        #expect(first.durationSeconds == 325)
        #expect(first.thumbnailUrl == "https://i.ytimg.com/vi/nEaJMdM1djM/mqdefault.jpg")
        #expect(first.watchUrl == "https://www.youtube.com/watch?v=nEaJMdM1djM")

        #expect(results.channels.map(\.title) == ["Fireship", "Beyond Fireship"])
        let channel = results.channels[0]
        #expect(channel.kind == .youtube)
        #expect(channel.feedUrl == FeedDetection.youtubeFeedURL(channelID: "UCsBjURrPoezykLs9EqgamOA"))
        #expect(channel.siteUrl == "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA")
        #expect(channel.imageUrl?.hasPrefix("https://yt3.ggpht.com/") == true)
        // The `@handle` is in the field that names the subscribers elsewhere; the count is not mistaken for it.
        #expect(channel.subtitle == "YouTube · 4.32M subscribers")
        #expect(results.channels[1].subtitle == "YouTube · 463K subscribers")
    }

    @Test func postsTheQueryWithoutAKey() async throws {
        let net = ExploreFixtures.Network(ExploreFixtures.youtube)
        _ = try await net.search(language: "de", region: "DE").videos("  swift concurrency ")
        let request = try #require(net.requests.first)
        #expect(request.url == "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        let body = try #require(request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["query"] as? String == "swift concurrency")
        let client = ((body["context"] as? [String: Any])?["client"]) as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB")
        #expect(client?["hl"] as? String == "de")
        #expect(client?["gl"] as? String == "DE")
    }

    @Test func aBlankQueryAsksNothing() async throws {
        let net = ExploreFixtures.Network(ExploreFixtures.youtube)
        #expect(try await net.search().videos("  ") == ExploreVideoResults())
        #expect(try await net.search().episodes("") == [])
        #expect(net.requests.isEmpty)
    }

    @Test func failuresThrow() async {
        await #expect(throws: HTTPError.status(429)) { try await ExploreFixtures.Network(Data(), status: 429).search().videos("x") }
        await #expect(throws: (any Error).self) { try await ExploreFixtures.Network(Data("<html>".utf8)).search().videos("x") }
        await #expect(throws: HTTPError.status(500)) { try await ExploreFixtures.Network(Data(), status: 500).search().episodes("x") }
        await #expect(throws: (any Error).self) { try await ExploreFixtures.Network(Data("<html>".utf8)).search().episodes("x") }
    }

    private func renderers(_ items: [String]) -> Data {
        Data(#"{"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[\#(items.joined(separator: ","))]}}]}}}"#.utf8)
    }

    private func video(_ id: String, extra: String = "") -> String {
        #"{"videoRenderer":{"videoId":"\#(id)","title":{"runs":[{"text":"Video \#(id)"}]},"lengthText":{"simpleText":"1:02:03"},"ownerText":{"runs":[{"text":"Ch"}]}\#(extra)}}"#
    }

    @Test func capsTheVideos() throws {
        let ids = (0..<30).map { String(format: "video%06d", $0) }
        let results = try DefaultExploreSearch.results(inSearch: renderers(ids.map { video($0) }))
        #expect(results.videos.count == DefaultExploreSearch.videoLimit)
        #expect(results.videos.map(\.id) == Array(ids.prefix(DefaultExploreSearch.videoLimit)))
        #expect(results.videos[0].durationSeconds == 3723)
        #expect(results.videos[0].channelID == nil)
        #expect(results.videos[0].views == nil)
    }

    @Test func leavesOutShortsAndStreams() throws {
        let short = video("short000001", extra: #","navigationEndpoint":{"reelWatchEndpoint":{"videoId":"short000001"}}"#)
        let live = #"{"videoRenderer":{"videoId":"live0000001","title":{"runs":[{"text":"Live"}]},"ownerText":{"runs":[{"text":"Ch"}]}}}"#
        let results = try DefaultExploreSearch.results(inSearch: renderers([short, live, video("video000001")]))
        #expect(results.videos.map(\.id) == ["video000001"])
    }

    @Test func readsChannelCountsInEitherOrder() throws {
        func subtitle(_ fields: String) throws -> String? {
            let channel = #"{"channelRenderer":{"channelId":"UCsBjURrPoezykLs9EqgamOA","title":{"simpleText":"Fireship"}\#(fields)}}"#
            return try DefaultExploreSearch.results(inSearch: renderers([channel])).channels.first?.subtitle
        }
        // Handle in subscriberCountText, subscribers in videoCountText (seen in 2026)...
        #expect(try subtitle(#","subscriberCountText":{"simpleText":"@Fireship"},"videoCountText":{"simpleText":"4.32M subscribers"}"#) == "YouTube · 4.32M subscribers")
        // ...and the long-standing order, whose videoCountText is a video count.
        #expect(try subtitle(#","subscriberCountText":{"simpleText":"4.32M subscribers"},"videoCountText":{"simpleText":"700 videos"}"#) == "YouTube · 4.32M subscribers")
        // Localized words: the handle still tells which is which.
        #expect(try subtitle(#","subscriberCountText":{"simpleText":"@Fireship"},"videoCountText":{"simpleText":"4,32 Mio. Abonnenten"}"#) == "YouTube · 4,32 Mio. Abonnenten")
        #expect(try subtitle(#","subscriberCountText":{"simpleText":"4,32 Mio. Abonnenten"},"videoCountText":{"simpleText":"700 Videos"}"#) == "YouTube · 4,32 Mio. Abonnenten")
        // Only a handle, or nothing: no count to show.
        #expect(try subtitle(#","subscriberCountText":{"simpleText":"@Fireship"}"#) == "YouTube")
        #expect(try subtitle("") == "YouTube")
        // Not a channel id: not a source to follow.
        let bad = #"{"channelRenderer":{"channelId":"notachannel","title":{"simpleText":"X"}}}"#
        #expect(try DefaultExploreSearch.results(inSearch: renderers([bad])).channels.isEmpty)
    }

    // MARK: Episodes

    @Test func readsEpisodesKeepingTwoPerShow() async throws {
        let net = ExploreFixtures.Network(ExploreFixtures.itunes)
        let episodes = try await net.search(region: "GB").episodes("roman empire")

        // The fixture holds 4, 3, 1 and 1 episodes of four shows.
        #expect(episodes.count == 6)
        var perShow: [String: Int] = [:]
        for e in episodes { perShow[e.showID, default: 0] += 1 }
        #expect(perShow.values.sorted() == [1, 1, 2, 2])
        #expect(Set(episodes.map(\.id)).count == episodes.count)

        let e = episodes[0]
        #expect(!e.title.isEmpty && !e.show.isEmpty)
        #expect(e.audioUrl?.hasPrefix("http") == true)
        #expect(e.artworkUrl?.hasPrefix("https://") == true)
        #expect(e.published != nil && e.durationSeconds != nil)
        #expect(e.feedUrl?.hasPrefix("http") == true)
        #expect(e.appleUrl == "https://podcasts.apple.com/gb/podcast/id\(e.showID)?i=\(e.id)")
        #expect(ApplePodcastEpisode.link(e.appleUrl) == ApplePodcastEpisode.Link(country: "gb", showID: e.showID, episodeID: e.id))

        let url = try #require(URLComponents(string: net.requests[0].url))
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "itunes.apple.com" && url.path == "/search")
        #expect(query["entity"] == "podcastEpisode" && query["media"] == "podcast")
        #expect(query["term"] == "roman empire" && query["country"] == "GB" && query["limit"] == "50")
        #expect(net.requests[0].body == nil)
    }

    @Test func capsTheEpisodes() throws {
        let rows = (0..<40).map { i in
            #"{"wrapperType":"podcastEpisode","trackId":\#(1000 + i),"collectionId":\#(i),"trackName":"Episode \#(i)","collectionName":"Show \#(i)","episodeUrl":"https://cdn.example.com/\#(i).mp3"}"#
        }
        let data = Data(#"{"resultCount":40,"results":[\#(rows.joined(separator: ","))]}"#.utf8)
        let episodes = try ApplePodcastEpisode.exploreEpisodes(search: data, country: "us", limit: DefaultExploreSearch.episodeLimit)
        #expect(episodes.count == DefaultExploreSearch.episodeLimit)
        #expect(episodes.map(\.id) == (0..<20).map { String(1000 + $0) })
    }

    @Test func episodeItemsAreWhatTheAppleLinkStores() throws {
        let hits = try ApplePodcastEpisode.exploreEpisodes(search: ExploreFixtures.itunes, country: "us", limit: 20)
        let hit = hits[0]
        let results = try #require(try JSONSerialization.jsonObject(with: ExploreFixtures.itunes) as? [String: Any])["results"] as? [[String: Any]]
        let raw = try #require(results?.first { ($0["trackId"] as? Int).map(String.init) == hit.id })

        // The lookup's answer for the same episode: the show, then its episodes.
        let show: [String: Any] = ["wrapperType": "track", "kind": "podcast", "feedUrl": hit.feedUrl as Any]
        let lookup = try JSONSerialization.data(withJSONObject: ["resultCount": 2, "results": [show, raw]])
        let link = try #require(ApplePodcastEpisode.link(hit.appleUrl))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let fromLookup = try #require(ApplePodcastEpisode.item(lookup: lookup, link: link, now: now).item)
        let fromHit = try #require(ApplePodcastEpisode.item(explore: hit, now: now))

        #expect(fromHit == fromLookup)
        #expect(fromHit.guid == hit.appleUrl)
        #expect(fromHit.audioUrl == hit.audioUrl)
        #expect(fromHit.author == hit.show)
        #expect(fromHit.summary?.isEmpty == false)
        #expect(OpenedLinks.feedURL(for: fromHit) == OpenedLinks.episodesFeedURL)
    }

    @Test func aHitWithoutAudioMakesNoItem() throws {
        var hit = try #require(try ApplePodcastEpisode.exploreEpisodes(search: ExploreFixtures.itunes, country: "us", limit: 1).first)
        hit.audioUrl = nil
        #expect(ApplePodcastEpisode.item(explore: hit) == nil)
    }
}

@Suite("Opening Explore results")
struct ExploreOpenTests {
    /// Reads no pages: `link` answers `fetchLinkItem`.
    struct FakeScraper: PageScraper {
        var link: ParsedItem?
        func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult { throw HTTPError.notHTTP }
        func findArticleLinks(html: String, pageURL: String) -> [String] { [] }
        func listingTitle(html: String, pageURL: String) -> String { "" }
        func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult { PageImageResult(image: nil, final: true) }
        func fetchLinkItem(url: String, videoID: String?, timeout: TimeInterval) async -> ParsedItem? { link }
    }

    func services(_ db: AppDatabase, link: ParsedItem? = nil) -> OpenDispatchServices {
        let live = OpenDispatchServices.live(database: db)
        return OpenDispatchServices(database: db, feedParser: live.feedParser, scraper: FakeScraper(link: link),
                                    detector: ServiceTests.FakeDetector(), extractor: ServiceTests.FakeExtractor(),
                                    opml: live.opml, integrations: live.integrations, refresh: live.refresh)
    }

    private let video = ExploreVideo(id: "nEaJMdM1djM", title: "Did the AI bubble just pop?", channel: "Fireship", duration: "5:25",
                                     thumbnailUrl: "https://i.ytimg.com/vi/nEaJMdM1djM/mqdefault.jpg")

    @Test func opensAnEpisodeWithoutAnyRequest() async throws {
        let db = try Fixture.db()
        let svc = services(db)
        let hit = try #require(try ApplePodcastEpisode.exploreEpisodes(search: ExploreFixtures.itunes, country: "us", limit: 1).first)
        let opened = try await svc.openExploreEpisode(hit)
        #expect(opened.item.guid == hit.appleUrl)
        #expect(opened.item.audioUrl == hit.audioUrl)
        #expect(opened.item.title == hit.title)
        #expect(opened.item.durationSec == hit.durationSeconds)
        #expect(opened.source.feedUrl == OpenedLinks.episodesFeedURL)
        #expect(opened.source.title == hit.show)
        // Opened again, it is the same row.
        #expect(try await svc.openExploreEpisode(hit).item.id == opened.item.id)
    }

    @Test func opensAVideoFromTheWatchPageWhenItReads() async throws {
        let page = ParsedItem(guid: video.watchUrl, url: video.watchUrl, title: "Did the AI bubble just pop? - YouTube", summary: "About the bubble.",
                              author: "Fireship", publishedAt: Fixture.base, thumbnailUrl: "https://i.ytimg.com/vi/nEaJMdM1djM/hqdefault.jpg",
                              videoId: video.id, durationSec: 325)
        let opened = try await services(try Fixture.db(), link: page).openExploreVideo(video)
        #expect(opened.item.summary == "About the bubble.")
        #expect(opened.item.videoId == video.id)
        #expect(opened.source.feedUrl == OpenedLinks.videosFeedURL)
    }

    @Test func opensAVideoFromTheHitWhenThePageDoesNotRead() async throws {
        let db = try Fixture.db()
        let svc = services(db)
        let opened = try await svc.openExploreVideo(video)
        #expect(opened.item.guid == video.watchUrl)
        #expect(opened.item.title == "Did the AI bubble just pop?")
        #expect(opened.item.author == "Fireship")
        #expect(opened.item.videoId == video.id)
        #expect(opened.item.durationSec == 325)
        #expect(opened.item.thumbnailUrl == "https://i.ytimg.com/vi/nEaJMdM1djM/hqdefault.jpg")
        #expect(opened.source.kind == .youtube)
        #expect(opened.source.title == "Fireship")
        // The same video opened from a pasted link is the same row.
        #expect(try await svc.openExploreVideo(video).item.id == opened.item.id)
        #expect(try await svc.openLink("https://youtu.be/nEaJMdM1djM").item.id == opened.item.id)
    }

    @Test func aPageThatGaveOnlyItsAddressTakesTheHitsTitleAndChannel() async throws {
        let bare = ParsedItem(guid: video.watchUrl, url: video.watchUrl, title: video.watchUrl, publishedAt: Fixture.base, videoId: video.id)
        let opened = try await services(try Fixture.db(), link: bare).openExploreVideo(video)
        #expect(opened.item.title == "Did the AI bubble just pop?")
        #expect(opened.item.author == "Fireship")
        #expect(opened.item.durationSec == 325)
    }
}
