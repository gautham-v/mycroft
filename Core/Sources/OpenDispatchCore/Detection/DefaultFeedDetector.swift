import Foundation

/// Port of `detectFeed` (src/lib/feed-detect.ts): Apple Podcasts shows (iTunes lookup), Spotify
/// rejection, YouTube channels (videos.xml feed, /channel/UC… or channelId in the page HTML), the
/// URL as a feed itself, `<link rel="alternate">` feeds, a www-alternate retry, and finally a
/// scraped-page source when the page has article links.
public struct DefaultFeedDetector: FeedDetector {
    /// GET `url` with extra headers; returns the body and response without checking the status.
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async throws -> (Data, HTTPURLResponse)

    let parser: any FeedParser
    let scraper: any PageScraper
    let fetch: Fetch

    public init(parser: any FeedParser, scraper: any PageScraper) {
        self.init(parser: parser, scraper: scraper, fetch: { url, headers in
            try await HTTP.fetch(url, timeout: FeedDetection.timeout, headers: headers)
        })
    }

    /// Tests inject a fake network.
    init(parser: any FeedParser, scraper: any PageScraper, fetch: @escaping Fetch) {
        self.parser = parser
        self.scraper = scraper
        self.fetch = fetch
    }

    public func detect(_ input: String) async throws -> DetectedFeed {
        let url = try SourceURL.normalize(input)

        if let appleID = FeedDetection.applePodcastID(url) {
            let feedURL = try await appleFeedURL(id: appleID)
            guard let r = try await tryFeed(feedURL, kind: .rss) else {
                throw FeedDetectionError("The podcast's RSS feed could not be read")
            }
            return r
        }
        if FeedDetection.isSpotifyShowURL(url) {
            throw FeedDetectionError(
                "Spotify does not expose RSS feeds. Search for the show on Apple Podcasts or its website and add that URL instead.")
        }

        if FeedDetection.isYouTubeURL(url) {
            return try await detectYouTube(url)
        }
        if let feedURL = FeedDetection.redditFeedURL(url) {
            guard var r = try await tryFeed(feedURL, kind: .rss) else {
                throw FeedDetectionError("Reddit didn't answer for that page. Try again in a moment.")
            }
            // Reddit's page refuses the app, and its feed's own title is a description.
            let path = feedURL.dropFirst(RedditPages.origin.count).split(separator: "/").map(String.init)
            r.title = path[0] == "r" ? "r/\(path[1])" : "u/\(path[1])"
            r.url = "\(RedditPages.origin)/\(path[0])/\(path[1])/"
            return r
        }
        if let place = FeedDetection.noFeedPlace(url) {
            throw FeedDetectionError("\(place) has no public feed, so its posts can't be followed here.")
        }

        let (data, res, finalURL) = try await fetchUserURL(url)
        guard Self.isOK(res) else { throw HTTPError.status(res.statusCode) }
        let text = HTTP.text(data, response: res)

        if FeedDetection.looksLikeFeed(text), let r = try await tryFeed(finalURL, kind: .rss, body: data) {
            return r
        }

        for candidate in FeedDetection.findAlternateFeeds(html: text, base: finalURL) {
            do {
                if var r = try await tryFeed(candidate, kind: .rss) {
                    r.url = FeedDetection.siteOrigin(nil, fallback: finalURL)
                    return r
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        // No feed anywhere: fall back to scraping the page for article links (kind 'page').
        if !scraper.findArticleLinks(html: text, pageURL: finalURL).isEmpty {
            // Keep the query (it may select a category); drop the fragment and trailing slash.
            let pageURL = FeedDetection.pageSourceURL(finalURL)
            return DetectedFeed(title: scraper.listingTitle(html: text, pageURL: finalURL), url: pageURL, feedUrl: pageURL,
                                kind: .page, group: SourceGroup.blogs)
        }
        throw FeedDetectionError("No RSS/Atom feed or article links found at that URL")
    }

    // MARK: - YouTube

    private func detectYouTube(_ url: String) async throws -> DetectedFeed {
        if let c = URLComponents(string: url), c.path.hasPrefix("/feeds/videos.xml"),
           let id = c.queryItems?.first(where: { $0.name == "channel_id" })?.value, !id.isEmpty,
           let r = try await tryFeed(FeedDetection.youtubeFeedURL(channelID: id), kind: .youtube) {
            return r
        }
        var id = FeedDetection.youtubeChannelID(fromURL: url)
        if id == nil {
            let (data, res, _) = try await fetchUserURL(url, headers: [
                "Accept-Language": "en-US,en;q=0.9",
                "Cookie": "CONSENT=YES+1",
            ])
            guard Self.isOK(res) else { throw FeedDetectionError("YouTube page returned HTTP \(res.statusCode)") }
            id = FeedDetection.findChannelID(inHTML: HTTP.text(data, response: res))
        }
        guard let id else { throw FeedDetectionError("Could not find YouTube channel id") }
        guard let r = try await tryFeed(FeedDetection.youtubeFeedURL(channelID: id), kind: .youtube) else {
            throw FeedDetectionError("YouTube feed not available for this channel")
        }
        return r
    }

    // MARK: - Feeds

    /// tryFeed: fetch (unless `body` is given) and parse `feedURL`; nil when it isn't a feed or the
    /// fetch isn't 2xx. Parse errors propagate.
    private func tryFeed(_ feedURL: String, kind: SourceKind, body: Data? = nil) async throws -> DetectedFeed? {
        let data: Data
        let text: String
        if let body {
            data = body
            text = HTTP.text(body)
        } else {
            let (d, res) = try await fetch(feedURL, ["Accept": HTTP.feedAccept])
            guard Self.isOK(res) else { return nil }
            data = d
            text = HTTP.text(d, response: res)
        }
        guard FeedDetection.looksLikeFeed(text) else { return nil }
        let feed = try parser.parse(data, kind: kind, feedURL: feedURL)

        if kind == .youtube {
            let id = feedURL.components(separatedBy: "channel_id=").dropFirst().first ?? ""
            return DetectedFeed(title: Self.nonEmpty(feed.title) ?? "YouTube channel",
                                url: "https://www.youtube.com/channel/\(id)", feedUrl: feedURL,
                                kind: .youtube, group: SourceGroup.youtube)
        }
        let title = Self.nonEmpty(feed.title) ?? FeedDetection.hostname(feedURL)
        let site = FeedDetection.siteOrigin(Self.nonEmpty(feed.link), fallback: feedURL)
        if feed.isPodcast {
            return DetectedFeed(title: title, url: site, feedUrl: feedURL, kind: .podcast, group: SourceGroup.podcast,
                                iconUrl: Self.nonEmpty(feed.imageUrl))
        }
        return DetectedFeed(title: title, url: site, feedUrl: feedURL, kind: kind, group: SourceGroup.blogs)
    }

    /// An Apple Podcasts show's RSS feed, from the iTunes lookup API.
    private func appleFeedURL(id: String) async throws -> String {
        let (data, res) = try await fetch("https://itunes.apple.com/lookup?id=\(id)&entity=podcast", ["Accept": "application/json"])
        guard Self.isOK(res) else { throw FeedDetectionError("Apple Podcasts lookup returned HTTP \(res.statusCode)") }
        struct Lookup: Decodable {
            struct Result: Decodable { let feedUrl: String? }
            let results: [Result]?
        }
        let body = try? JSONDecoder().decode(Lookup.self, from: data)
        guard let feedURL = body?.results?.lazy.compactMap({ Self.nonEmpty($0.feedUrl) }).first else {
            throw FeedDetectionError("Apple Podcasts has no public RSS feed for this show")
        }
        return feedURL
    }

    // MARK: - Fetching user URLs

    /// fetchUserUrl: fetch `url`; if that fails (network error or non-2xx) retry once with `www.`
    /// added or removed. Returns the first OK response and the URL it ended at after redirects, or
    /// the original failure (thrown error or non-OK response) when neither works.
    private func fetchUserURL(_ url: String, headers: [String: String] = [:]) async throws
        -> (data: Data, response: HTTPURLResponse, url: String) {
        var first: (Data, HTTPURLResponse)?
        var firstError: (any Error)?
        do {
            let r = try await fetch(url, headers)
            if Self.isOK(r.1) { return (r.0, r.1, Self.finalURL(r.1, fallback: url)) }
            first = r
        } catch HTTPError.timedOut {
            // A timeout already spent the budget; don't spend it twice.
            throw HTTPError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            firstError = error
        }
        if let alt = SourceURL.wwwAlternate(url), let r = try? await fetch(alt, headers), Self.isOK(r.1) {
            return (r.0, r.1, Self.finalURL(r.1, fallback: alt))
        }
        if let first { return (first.0, first.1, Self.finalURL(first.1, fallback: url)) }
        // A bare transport error (DNS, refused, TLS) says nothing useful to the user.
        if let e = firstError as? URLError, e.code != .cancelled {
            throw FeedDetectionError("Could not reach \(FeedDetection.hostname(url))")
        }
        throw firstError ?? FeedDetectionError("Could not reach \(FeedDetection.hostname(url))")
    }

    private static func isOK(_ res: HTTPURLResponse) -> Bool { (200..<300).contains(res.statusCode) }

    private static func finalURL(_ res: HTTPURLResponse, fallback: String) -> String {
        guard let u = res.url?.absoluteString, !u.isEmpty else { return fallback }
        return u
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
