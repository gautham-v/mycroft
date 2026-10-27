import Foundation

/// One match for a name typed into "Add sources". `feedUrl` is what gets added (through the detector,
/// like a pasted URL), so a result is only ever a suggestion until the feed is read.
public struct SourceSearchResult: Sendable, Hashable, Identifiable {
    public var title: String
    /// Host for sites and channels, the publisher for podcasts.
    public var subtitle: String
    public var feedUrl: String
    public var siteUrl: String?
    public var kind: SourceKind
    /// Podcast artwork; sites use SourceBadge's favicon instead.
    public var imageUrl: String?

    public var id: String { feedUrl }

    public init(title: String, subtitle: String, feedUrl: String, siteUrl: String? = nil, kind: SourceKind, imageUrl: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.feedUrl = feedUrl
        self.siteUrl = siteUrl
        self.kind = kind
        self.imageUrl = imageUrl
    }
}

/// Search sources by name: feeds (sites, newsletters, YouTube channels) from Feedly's public feed
/// search, podcasts from the iTunes Search API. Neither needs a key.
public protocol SourceSearching: Sendable {
    /// Results in display order, deduplicated by feed. Throws only when every provider failed.
    func search(_ query: String) async throws -> [SourceSearchResult]
}

public struct DefaultSourceSearch: SourceSearching {
    typealias Fetch = @Sendable (_ url: String) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 8
    static let feedLimit = 12
    static let podcastLimit = 6
    /// With this many name matches, results that don't match the name are left out.
    static let enoughMatches = 3
    /// Feeds Feedly hasn't seen update in this long are left out (dead blogs, retired feeds).
    static let staleAfter: TimeInterval = 2 * 365 * 86_400

    let fetch: Fetch
    let now: @Sendable () -> Date

    public init() {
        self.init(fetch: { url in
            try await HTTP.fetch(url, timeout: Self.timeout, headers: ["Accept": "application/json"])
        })
    }

    /// Tests inject a fake network and clock.
    init(fetch: @escaping Fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    public func search(_ query: String) async throws -> [SourceSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        async let feeds = Self.attempt { try await self.feeds(q) }
        async let podcasts = Self.attempt { try await self.podcasts(q) }
        let (f, p) = await (feeds, podcasts)
        if case .failure(let error) = f, case .failure = p { throw error }
        return Self.merge(query: q, feeds: (try? f.get()) ?? [], podcasts: (try? p.get()) ?? [])
    }

    private static func attempt(_ body: () async throws -> [SourceSearchResult]) async -> Result<[SourceSearchResult], any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Results whose title or publisher contains every word of the query come first, feeds and podcasts
    /// alternating (each list is already ranked). The rest follow only when there are few name matches:
    /// iTunes also matches episode text, so "fireship" finds unrelated shows that once mentioned it. A feed that
    /// is also a podcast keeps its podcast entry, which has the artwork and the right kind.
    static func merge(query: String, feeds: [SourceSearchResult], podcasts: [SourceSearchResult]) -> [SourceSearchResult] {
        let podcastKeys = Set(podcasts.map { SourceSearch.feedKey($0.feedUrl) })
        let feeds = feeds.filter { !podcastKeys.contains(SourceSearch.feedKey($0.feedUrl)) }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        func relevant(_ r: SourceSearchResult) -> Bool {
            let text = (r.title + " " + r.subtitle).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let (f, p) = (feeds.filter(relevant), podcasts.filter(relevant))
        var ordered: [SourceSearchResult] = []
        for i in 0..<max(f.count, p.count) {
            if i < f.count { ordered.append(f[i]) }
            if i < p.count { ordered.append(p[i]) }
        }
        if ordered.count < Self.enoughMatches {
            ordered += feeds.filter { !relevant($0) } + podcasts.filter { !relevant($0) }
        }
        var seen: Set<String> = []
        return ordered.filter { seen.insert(SourceSearch.feedKey($0.feedUrl)).inserted }
    }

    // MARK: - Feedly

    private struct FeedlyResponse: Decodable {
        struct Feed: Decodable {
            let feedId: String?
            let title: String?
            let website: String?
            let lastUpdated: Double?
        }
        let results: [Feed]?
    }

    private func feeds(_ q: String) async throws -> [SourceSearchResult] {
        var c = URLComponents(string: "https://cloud.feedly.com/v3/search/feeds")!
        c.queryItems = [URLQueryItem(name: "query", value: q), URLQueryItem(name: "count", value: String(Self.feedLimit + 8))]
        let (data, res) = try await fetch(c.string!)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        let body = try JSONDecoder().decode(FeedlyResponse.self, from: data)
        let cutoff = now().addingTimeInterval(-Self.staleAfter).timeIntervalSince1970 * 1000
        let results = (body.results ?? []).compactMap { f -> SourceSearchResult? in
            if let updated = f.lastUpdated, updated < cutoff { return nil }
            return Self.feedResult(feedId: f.feedId, title: f.title, website: f.website)
        }
        return Array(results.prefix(Self.feedLimit))
    }

    /// A Feedly search hit as a result: `feed/<url>` ids, YouTube uploads playlists turned into the
    /// channel's videos.xml feed, and the long-dead gdata YouTube feeds dropped.
    static func feedResult(feedId: String?, title: String?, website: String?) -> SourceSearchResult? {
        guard let id = feedId, id.hasPrefix("feed/") else { return nil }
        var feedURL = String(id.dropFirst("feed/".count))
        guard let host = URLComponents(string: feedURL)?.host?.lowercased() else { return nil }
        if host == "gdata.youtube.com" { return nil }

        var kind = SourceKind.rss
        var site = website?.trimmingCharacters(in: .whitespacesAndNewlines)
        if FeedDetection.isYouTubeURL(feedURL) {
            let items = URLComponents(string: feedURL)?.queryItems ?? []
            let channel: String?
            if let list = items.first(where: { $0.name == "list" })?.value, list.hasPrefix("UU"), list.count == 24 {
                channel = "UC" + list.dropFirst(2)
            } else {
                channel = items.first(where: { $0.name == "channel_id" })?.value
            }
            guard let channel, channel.hasPrefix("UC") else { return nil }
            feedURL = FeedDetection.youtubeFeedURL(channelID: channel)
            site = "https://www.youtube.com/channel/\(channel)"
            kind = .youtube
        }

        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" (uploads) on YouTube", " on YouTube"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        let shownHost = kind == .youtube ? "YouTube" : URLHost.host(of: site?.isEmpty == false ? site! : feedURL)
        if name.isEmpty { name = shownHost }
        return SourceSearchResult(title: name, subtitle: shownHost, feedUrl: feedURL, siteUrl: site, kind: kind)
    }

    // MARK: - iTunes

    private struct ITunesResponse: Decodable {
        struct Show: Decodable {
            let collectionName: String?
            let artistName: String?
            let feedUrl: String?
            let artworkUrl100: String?
            let collectionViewUrl: String?
        }
        let results: [Show]?
    }

    private func podcasts(_ q: String) async throws -> [SourceSearchResult] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(Self.podcastLimit)), URLQueryItem(name: "term", value: q),
        ]
        let (data, res) = try await fetch(c.string!)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        let body = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return (body.results ?? []).compactMap { show in
            guard let feed = show.feedUrl, !feed.isEmpty, let name = show.collectionName, !name.isEmpty else { return nil }
            return SourceSearchResult(title: name, subtitle: show.artistName ?? "Podcast", feedUrl: feed,
                                      siteUrl: show.collectionViewUrl, kind: .podcast, imageUrl: show.artworkUrl100)
        }
    }
}

/// Search helpers the UI uses without a service.
public enum SourceSearch {
    /// The links in what was typed or pasted into "Add sources": every whitespace- or comma-separated
    /// part, normalized, when each one looks like a URL (has a dot and normalizes). Empty for a name.
    public static func links(in text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !parts.isEmpty else { return [] }
        var out: [String] = []
        for part in parts {
            guard part.contains("."), let url = try? SourceURL.normalize(part) else { return [] }
            if !out.contains(url) { out.append(url) }
        }
        return out
    }

    /// A feed URL without scheme, `www.` or a trailing slash, for spotting the same feed twice.
    public static func feedKey(_ url: String) -> String {
        var s = url.lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
