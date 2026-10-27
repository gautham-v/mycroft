import Foundation
import Testing
@testable import OpenDispatchCore

/// Saved answers of the iTunes lookup API for Lenny's Podcast (a show with its newest episodes, and the show alone)
/// and a trimmed copy of its feed, in Fixtures/ApplePodcasts.
enum ApplePodcastFixtures {
    static let showFeedURL = "https://api.substack.com/feed/podcast/10845.rss"
    static let episodeID = "1000793099277"
    static let audio = "https://pscrb.fm/rss/p/api.substack.com/feed/podcast/217274136/13e3f49711c936b294b6ef27d4160818.mp3"

    static func data(_ name: String, _ ext: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "ApplePodcasts"),
              let data = try? Data(contentsOf: url) else { fatalError("missing fixture \(name).\(ext)") }
        return data
    }

    static var episodes: Data { data("lookup-episodes", "json") }
    static var show: Data { data("lookup-show", "json") }
    static var feed: Data { data("show-feed", "xml") }

    /// A `Fetch` answering by URL (any limit for the episodes lookup), recording what was asked.
    final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        let routes: [String: Data]
        init(_ routes: [String: Data]) { self.routes = routes }
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return asked }

        var fetch: ApplePodcastEpisode.Fetch {
            { url in
                self.lock.lock(); self.asked.append(url); self.lock.unlock()
                if let data = self.routes[url] { return data }
                if url.contains("entity=podcastEpisode") { return self.routes["episodes"] ?? Data() }
                throw HTTPError.status(404)
            }
        }
    }
}

@Suite("Apple Podcasts episodes")
struct ApplePodcastEpisodeTests {
    private let link = ApplePodcastEpisode.Link(country: "us", showID: "1627920305", episodeID: ApplePodcastFixtures.episodeID)

    @Test func parsesEpisodeLinks() {
        let page = "https://podcasts.apple.com/us/podcast/openais-head-of-chatgpt/id1627920305?i=1000793099277"
        #expect(ApplePodcastEpisode.link(page) == link)
        #expect(ApplePodcastEpisode.link(page + "&uo=4") == link)
        #expect(ApplePodcastEpisode.link("https://itunes.apple.com/us/podcast/some-show/id1627920305?i=1000793099277&mt=2") == link)
        #expect(ApplePodcastEpisode.link("https://podcasts.apple.com/gb/podcast/id1627920305?i=1000793099277")?.country == "gb")
        // No store in the path: the US one.
        #expect(ApplePodcastEpisode.link("https://podcasts.apple.com/podcast/id1627920305?i=1000793099277")?.country == "us")
        // A show link, a non-numeric episode, and other sites are not episodes.
        #expect(ApplePodcastEpisode.link("https://podcasts.apple.com/us/podcast/some-show/id1627920305") == nil)
        #expect(ApplePodcastEpisode.link("https://podcasts.apple.com/us/podcast/some-show/id1627920305?i=abc") == nil)
        #expect(ApplePodcastEpisode.link("https://open.spotify.com/episode/6mYNtYPOtQeOFVQJxsKJcF") == nil)
        #expect(ApplePodcastEpisode.link("https://example.com/podcast/id1627920305?i=1000793099277") == nil)
    }

    @Test func oneAddressForEveryLinkToAnEpisode() {
        #expect(ApplePodcastEpisode.canonicalURL(link) == "https://podcasts.apple.com/us/podcast/id1627920305?i=1000793099277")
        #expect(ApplePodcastEpisode.lookupURL(showID: "1", country: "us", limit: 20)
                == "https://itunes.apple.com/lookup?id=1&country=us&media=podcast&entity=podcastEpisode&limit=20")
        #expect(ApplePodcastEpisode.lookupURL(showID: "1", country: "us", limit: 0)
                == "https://itunes.apple.com/lookup?id=1&country=us&media=podcast&entity=podcast")
    }

    @Test func mapsALookupAnswerToAnItem() throws {
        let found = ApplePodcastEpisode.item(lookup: ApplePodcastFixtures.episodes, link: link)
        #expect(found.feedURL == ApplePodcastFixtures.showFeedURL)
        #expect(found.listed == 2)
        let item = try #require(found.item)
        #expect(item.guid == "https://podcasts.apple.com/us/podcast/id1627920305?i=1000793099277")
        #expect(item.url == "https://podcasts.apple.com/us/podcast/openais-head-of-chatgpt-were-entering-a-new-era/id1627920305?i=1000793099277")
        #expect(item.title == "OpenAI\u{2019}s Head of ChatGPT: We\u{2019}re entering a new era of AI (again) | Tibo Sottiaux")
        #expect(item.author == "Lenny's Podcast: Product | Career | Growth")
        #expect(item.audioUrl == ApplePodcastFixtures.audio)
        #expect(item.durationSec == 2243)
        #expect(item.thumbnailUrl?.hasSuffix("600x600bb.jpg") == true)
        #expect(item.summary?.hasPrefix("Tibo Sottiaux leads ChatGPT and Codex at OpenAI.") == true)
        #expect(item.publishedAt == ISO8601.date(from: "2026-10-04T12:32:47Z"))
        #expect(item.videoId == nil)
        #expect(OpenedLinks.feedURL(for: item) == OpenedLinks.episodesFeedURL)

        // An episode the answer doesn't list: no item, but the show's feed is known.
        let other = ApplePodcastEpisode.Link(country: "us", showID: "1627920305", episodeID: "1000000000001")
        let missing = ApplePodcastEpisode.item(lookup: ApplePodcastFixtures.episodes, link: other)
        #expect(missing.item == nil)
        #expect(missing.feedURL == ApplePodcastFixtures.showFeedURL)
        #expect(ApplePodcastEpisode.item(lookup: Data("not json".utf8), link: link).item == nil)
    }

    @Test func resolvesFromTheNewestEpisodes() async throws {
        let net = ApplePodcastFixtures.Network(["episodes": ApplePodcastFixtures.episodes])
        let item = await ApplePodcastEpisode.resolve(link, fetch: net.fetch, pageTitle: { nil })
        #expect(item?.audioUrl == ApplePodcastFixtures.audio)
        // The small lookup was enough.
        #expect(net.requests == [ApplePodcastEpisode.lookupURL(showID: "1627920305", country: "us", limit: 20)])
    }

    @Test func anOlderEpisodeIsFoundInTheShowsFeedByTitle() async throws {
        let net = ApplePodcastFixtures.Network(["episodes": ApplePodcastFixtures.episodes, ApplePodcastFixtures.showFeedURL: ApplePodcastFixtures.feed])
        let older = ApplePodcastEpisode.Link(country: "us", showID: "1627920305", episodeID: "1000651671547")
        // Apple's title and the feed's differ in punctuation.
        let item = try #require(await ApplePodcastEpisode.resolve(
            older, fetch: net.fetch, pageTitle: { "An older episode \u{2013} why PMF isn\u{2019}t a moment" }))
        #expect(item.guid == "https://podcasts.apple.com/us/podcast/id1627920305?i=1000651671547")
        #expect(item.url == item.guid)
        #expect(item.title == "An older episode: why PMF isn't a moment")
        #expect(item.audioUrl == "https://cdn.example.com/older.mp3?x=1")
        #expect(item.durationSec == 3665)
        #expect(item.author == "Lenny's Podcast: Product | Career | Growth")
        #expect(item.thumbnailUrl == "https://example.com/show-art.jpg")

        // The first lookup listed fewer than asked for, so asking for more would not help; then the feed was read.
        #expect(net.requests == [
            ApplePodcastEpisode.lookupURL(showID: "1627920305", country: "us", limit: 20),
            ApplePodcastFixtures.showFeedURL,
        ])
        // Unknown to the feed too, or no page title to match: nothing.
        #expect(await ApplePodcastEpisode.resolve(older, fetch: net.fetch, pageTitle: { "Something else" }) == nil)
        #expect(await ApplePodcastEpisode.resolve(older, fetch: net.fetch, pageTitle: { nil }) == nil)
        #expect(await ApplePodcastEpisode.resolve(older, fetch: ApplePodcastFixtures.Network([:]).fetch, pageTitle: { "x" }) == nil)
    }

    @Test func showFeedAndEntry() async throws {
        let net = ApplePodcastFixtures.Network([ApplePodcastEpisode.lookupURL(showID: "1627920305", country: "us", limit: 0): ApplePodcastFixtures.show])
        #expect(await ApplePodcastEpisode.feedURL(showID: "1627920305", country: "us", fetch: net.fetch) == ApplePodcastFixtures.showFeedURL)
        #expect(await ApplePodcastEpisode.feedURL(showID: "9", country: "us", fetch: net.fetch) == nil)

        // The feed's own guid and link, found by the audio URL, or by title when the audio differs.
        let parsed = try #require(ApplePodcastEpisode.item(lookup: ApplePodcastFixtures.episodes, link: link).item)
        var item = Item(sourceId: 1, guid: parsed.guid, url: parsed.url, title: parsed.title, publishedAt: parsed.publishedAt, audioUrl: parsed.audioUrl)
        let entry = try #require(ApplePodcastEpisode.entry(in: ApplePodcastFixtures.feed, feedURL: ApplePodcastFixtures.showFeedURL, for: item, parser: DefaultFeedParser()))
        #expect(entry.guid == "substack:post:217274136")
        #expect(entry.url == "https://www.lennysnewsletter.com/p/openais-head-of-chatgpt-were-entering")
        item.audioUrl = "https://elsewhere.example.com/other.mp3"
        item.title = "OpenAI's head of ChatGPT: we're entering a new era of AI (again) - Tibo Sottiaux"
        #expect(ApplePodcastEpisode.entry(in: ApplePodcastFixtures.feed, feedURL: ApplePodcastFixtures.showFeedURL, for: item, parser: DefaultFeedParser())?.guid
                == "substack:post:217274136")
        item.title = "A different episode"
        #expect(ApplePodcastEpisode.entry(in: ApplePodcastFixtures.feed, feedURL: ApplePodcastFixtures.showFeedURL, for: item, parser: DefaultFeedParser()) == nil)
    }

    @Test func showNotesComeFromTheShowsFeed() async throws {
        let db = try Fixture.db()
        let parsed = try #require(ApplePodcastEpisode.item(lookup: ApplePodcastFixtures.episodes, link: link).item)
        let opened = try await db.insertOpenedLink(parsed)
        let extractor = EpisodeExtractorStub()
        var content = ContentService(database: db, extractor: extractor)
        let net = ApplePodcastFixtures.Network([ApplePodcastEpisode.lookupURL(showID: "1627920305", country: "us", limit: 0): ApplePodcastFixtures.show])
        content.lookup = net.fetch

        let result = try await content.content(forItem: opened.id)
        #expect(result.contentHtml == "<p>Notes</p>")
        #expect(extractor.calls == [.init(url: ApplePodcastFixtures.audio, feed: FeedRef(feedUrl: ApplePodcastFixtures.showFeedURL, guid: parsed.guid))])
        // Cached after the first time.
        _ = try await content.content(forItem: opened.id)
        #expect(extractor.calls.count == 1)

        // The same entry is what the real parser finds in the feed by that audio URL.
        let html = DefaultFeedParser().itemHTML(in: ApplePodcastFixtures.feed, guid: parsed.guid, url: ApplePodcastFixtures.audio)
        #expect(html?.contains("Tibo Sottiaux leads ChatGPT") == true)
    }

    @Test func anAudioFileHasNoShowNotes() async throws {
        let db = try Fixture.db()
        let opened = try await db.insertOpenedLink(OpenedLinks.audioItem(url: "https://cdn.example.com/talk.mp3"))
        let extractor = EpisodeExtractorStub()
        let content = ContentService(database: db, extractor: extractor)
        #expect(try await content.content(forItem: opened.id).contentHtml == nil)
        #expect(extractor.calls.isEmpty)
    }
}

/// Records what the show-notes extraction was asked for.
final class EpisodeExtractorStub: ContentExtractor, @unchecked Sendable {
    struct Call: Equatable {
        var url: String
        var feed: FeedRef
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult { ExtractResult(contentHtml: nil, leadImage: nil) }

    func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult {
        lock.lock(); recorded.append(Call(url: url, feed: feed)); lock.unlock()
        return ExtractResult(contentHtml: "<p>Notes</p>", leadImage: nil)
    }
}
