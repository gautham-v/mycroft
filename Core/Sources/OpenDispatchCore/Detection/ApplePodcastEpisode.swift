import Foundation

/// An Apple Podcasts (or itunes.apple.com) episode link, opened as a playable episode (OpenedLinks).
///
/// The iTunes lookup API can't be asked for one episode (an episode id returns nothing), so the show is
/// looked up with its newest episodes and the episode picked out by id. One older than those, or one the
/// lookup doesn't list, is found in the show's own feed by its title. Either way the item has the audio
/// URL, so the reader plays it; its show notes and transcript are read from the same feed later
/// (`feedURL(showID:country:fetch:)`, `entry(in:for:)`). Nothing is stored beyond an ordinary item.
enum ApplePodcastEpisode {
    struct Link: Equatable {
        var country: String
        var showID: String
        var episodeID: String
    }

    /// The body of a GET. The live one adds a timeout and requires 2xx; tests answer from fixtures.
    typealias Fetch = @Sendable (String) async throws -> Data

    /// How many of the show's newest episodes to ask for: a small answer first, then the lookup API's maximum.
    static let lookupLimits = [20, 200]

    /// The episode in `https://podcasts.apple.com/<country>/podcast/<slug>/id<show>?i=<episode>`; nil for
    /// a show link (no `i`) and for any other URL.
    static func link(_ url: String) -> Link? {
        guard let showID = FeedDetection.applePodcastID(url), let c = URLComponents(string: url),
              let episodeID = c.queryItems?.first(where: { $0.name == "i" })?.value,
              !episodeID.isEmpty, episodeID.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        let first = c.path.split(separator: "/").first.map(String.init) ?? ""
        let country = first.count == 2 && first.allSatisfy({ $0.isASCII && $0.isLetter }) ? first.lowercased() : "us"
        return Link(country: country, showID: showID, episodeID: episodeID)
    }

    /// The one address every link to the episode is stored under (its item's guid), whatever the host,
    /// slug or tracking parameters it was shared with. Apple redirects it to the slugged page.
    static func canonicalURL(_ link: Link) -> String {
        "https://podcasts.apple.com/\(link.country)/podcast/id\(link.showID)?i=\(link.episodeID)"
    }

    /// The show with its newest `limit` episodes; 0 for the show alone.
    static func lookupURL(showID: String, country: String, limit: Int) -> String {
        let base = "https://itunes.apple.com/lookup?id=\(showID)&country=\(country)&media=podcast"
        return limit > 0 ? "\(base)&entity=podcastEpisode&limit=\(limit)" : "\(base)&entity=podcast"
    }

    // MARK: Resolving

    /// The episode as an item (nil when Apple doesn't know it). `pageTitle` reads the episode page's title, only
    /// asked for when the lookup doesn't list the episode.
    static func resolve(_ link: Link, fetch: Fetch, parser: any FeedParser = DefaultFeedParser(),
                        pageTitle: () async -> String?) async -> ParsedItem? {
        var feedURL: String?
        for limit in lookupLimits {
            guard let data = try? await fetch(lookupURL(showID: link.showID, country: link.country, limit: limit)) else { break }
            let found = item(lookup: data, link: link)
            if let item = found.item { return item }
            feedURL = found.feedURL ?? feedURL
            if found.listed < limit { break }
        }
        guard let feedURL, let title = await pageTitle(), let feed = try? await fetch(feedURL) else { return nil }
        return item(feed: feed, feedURL: feedURL, title: title, link: link, parser: parser)
    }

    /// The show's RSS feed, from the lookup API.
    static func feedURL(showID: String, country: String, fetch: Fetch) async -> String? {
        guard let data = try? await fetch(lookupURL(showID: showID, country: country, limit: 0)) else { return nil }
        return decode(data).show?.feedUrl.flatMap(nonEmpty)
    }

    // MARK: Lookup JSON

    private struct Result: Decodable {
        var wrapperType: String?
        var trackId: Int64?
        var trackName: String?
        var collectionName: String?
        var description: String?
        var shortDescription: String?
        var releaseDate: String?
        var trackTimeMillis: Int?
        var artworkUrl600: String?
        var episodeUrl: String?
        var trackViewUrl: String?
        var feedUrl: String?
        var episodeGuid: String?
    }

    private struct Response: Decodable {
        var results: [Result]?
    }

    private static func decode(_ data: Data) -> (show: Result?, episodes: [Result]) {
        let results = (try? JSONDecoder().decode(Response.self, from: data))?.results ?? []
        return (results.first { $0.wrapperType != "podcastEpisode" }, results.filter { $0.wrapperType == "podcastEpisode" })
    }

    /// The episode in a lookup answer, with the show's feed URL and how many episodes the answer listed.
    static func item(lookup data: Data, link: Link, now: Date = Date()) -> (item: ParsedItem?, feedURL: String?, listed: Int) {
        let (show, episodes) = decode(data)
        let feedURL = (show?.feedUrl ?? episodes.first?.feedUrl).flatMap(nonEmpty)
        guard let r = episodes.first(where: { $0.trackId.map(String.init) == link.episodeID }),
              let audio = r.episodeUrl.flatMap(nonEmpty), let title = r.trackName.flatMap(nonEmpty)
        else { return (nil, feedURL, episodes.count) }
        let parsed = ParsedItem(
            guid: canonicalURL(link), url: pageURL(r.trackViewUrl, link: link), title: title,
            summary: (r.description.flatMap(nonEmpty) ?? r.shortDescription.flatMap(nonEmpty)),
            author: r.collectionName.flatMap(nonEmpty),
            publishedAt: r.releaseDate.flatMap(ISO8601.date(from:)) ?? now,
            thumbnailUrl: r.artworkUrl600.flatMap(nonEmpty), durationSec: r.trackTimeMillis.map { $0 / 1000 },
            audioUrl: audio)
        return (parsed, feedURL, episodes.count)
    }

    // MARK: Feed

    /// The episode in the show's feed, by title, as an item stored under the Apple link.
    static func item(feed data: Data, feedURL: String, title: String, link: Link, parser: any FeedParser) -> ParsedItem? {
        guard let feed = try? parser.parse(data, kind: .podcast, feedURL: feedURL) else { return nil }
        let key = titleKey(title)
        guard !key.isEmpty, var item = feed.items.first(where: { $0.audioUrl != nil && titleKey($0.title) == key }) else { return nil }
        item.guid = canonicalURL(link)
        item.url = canonicalURL(link)
        item.author = feed.title.flatMap(nonEmpty) ?? item.author
        item.thumbnailUrl = item.thumbnailUrl ?? feed.imageUrl
        return item
    }

    /// The feed's own entry for an opened episode, matched by its audio URL and then its title; carries the
    /// feed's guid and link, which the transcript lookups need.
    static func entry(in data: Data, feedURL: String, for item: Item, parser: any FeedParser) -> ParsedItem? {
        guard let feed = try? parser.parse(data, kind: .podcast, feedURL: feedURL) else { return nil }
        if let audio = item.audioUrl.map(FeedParsingSupport.linkMatchKey),
           let hit = feed.items.first(where: { $0.audioUrl.map(FeedParsingSupport.linkMatchKey) == audio }) { return hit }
        let key = titleKey(item.title)
        return key.isEmpty ? nil : feed.items.first { titleKey($0.title) == key }
    }

    // MARK: Helpers

    /// Titles compared by their letters and digits only: Apple and the feed differ in quotes, dashes and spacing.
    static func titleKey(_ title: String) -> String {
        String(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The slugged page address the lookup gives, without its tracking parameters; the canonical one without it.
    private static func pageURL(_ viewURL: String?, link: Link) -> String {
        guard let viewURL, var c = URLComponents(string: viewURL), let host = c.host, host.hasSuffix("apple.com") else {
            return canonicalURL(link)
        }
        c.host = "podcasts.apple.com"
        c.queryItems = [URLQueryItem(name: "i", value: link.episodeID)]
        return c.string ?? canonicalURL(link)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The live `Fetch`: GET with a timeout, 2xx required.
    static func liveFetch(session: URLSession = HTTP.session, timeout: TimeInterval = 15) -> Fetch {
        { url in try await HTTP.fetchOK(url, timeout: timeout, headers: ["Accept": HTTP.feedAccept], session: session).data }
    }
}
