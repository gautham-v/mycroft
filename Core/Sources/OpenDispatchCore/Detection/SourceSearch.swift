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
    /// Podcast artwork, or a channel's or X account's avatar; sites use SourceBadge's favicon instead.
    public var imageUrl: String?
    /// A YouTube channel's or X account's handle, without the "@".
    public var handle: String?
    /// How many follow it, as the place words it: "21.4M subscribers", "4.4M followers".
    public var audience: String?

    public var id: String { feedUrl }

    /// An X account, which is a scraped page source (`PageScraping`) rather than a feed.
    public var isXAccount: Bool { kind == .page && handle != nil }

    public init(title: String, subtitle: String, feedUrl: String, siteUrl: String? = nil, kind: SourceKind, imageUrl: String? = nil,
                handle: String? = nil, audience: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.feedUrl = feedUrl
        self.siteUrl = siteUrl
        self.kind = kind
        self.imageUrl = imageUrl
        self.handle = handle
        self.audience = audience
    }
}

/// What "Add sources" shows for a name, by place. `all` is the first X accounts and channels (the X and YouTube filters have the
/// rest), then sites and podcasts alternating.
public struct SourceSearchSections: Sendable, Equatable {
    public var x: [SourceSearchResult] = []
    public var youtube: [SourceSearchResult] = []
    public var sites: [SourceSearchResult] = []
    public var podcasts: [SourceSearchResult] = []
    public var all: [SourceSearchResult] = []

    public init() {}
}

/// A pasted link to an X account or a YouTube channel, which "Add sources" can show by name before it is added.
public enum SourceAccountLink: Sendable, Equatable {
    case x(handle: String)
    case youtubeHandle(String)
    case youtubeChannel(id: String)
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
        func relevant(_ r: SourceSearchResult) -> Bool { SourceSearch.matches(r, query: query) }
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

    /// The result's title or publisher contains every word of the query.
    static func matches(_ result: SourceSearchResult, query: String) -> Bool {
        let text = (result.title + " " + result.subtitle).lowercased()
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }

    /// The query without an "@" in front of it, which only says it is a handle.
    public static func name(in query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.hasPrefix("@") ? String(q.dropFirst()) : q
    }

    /// The X account a query could be: one word X allows as a handle, with or without the "@".
    public static func xHandle(in query: String) -> String? {
        let name = name(in: query)
        return name.wholeMatch(of: #/[A-Za-z0-9_]{1,15}/#) != nil ? name : nil
    }

    /// The account a link is the page of; nil for any other link, including a post on X or a video.
    public static func accountLink(_ url: String) -> SourceAccountLink? {
        guard let c = URLComponents(string: url), let host = c.host else { return nil }
        let segments = c.path.split(separator: "/").map(String.init)
        if PageScraping.isXHost(host) {
            return segments.count == 1 ? xHandle(in: segments[0]).map { .x(handle: $0) } : nil
        }
        guard FeedDetection.isYouTubeURL(url), !c.path.hasPrefix("/feeds/") else { return nil }
        if let id = FeedDetection.youtubeChannelID(fromURL: url) { return .youtubeChannel(id: id) }
        if let first = segments.first, first.hasPrefix("@"), first.count > 1 { return .youtubeHandle(String(first.dropFirst())) }
        return nil
    }

    /// Fewer subscribers than this and a channel is left out, unless its handle is what was typed: YouTube answers a name
    /// with every channel that uses it ("fireship" finds a FireShip with 3 subscribers).
    static let minSubscribers: Double = 1000

    /// "21.4M subscribers" as a number; nil when it doesn't start with one.
    static func subscriberCount(_ text: String?) -> Double? {
        guard let text, let m = text.replacing(",", with: "").prefixMatch(of: #/([\d.]+)\s*([KMB]?)/#), let n = Double(m.1) else { return nil }
        return n * (["K": 1e3, "M": 1e6, "B": 1e9][String(m.2)] ?? 1)
    }

    /// Sorts what the searches found by place. A query with an "@" keeps only the channel with that handle. Once an account
    /// or channel matched, sites and podcasts must match by name too (the search's fallback for few matches, unrelated shows,
    /// has no use then). Feedly's copies of a channel go, and so do its feeds of an X account, third-party bridges that the
    /// account itself replaces.
    public static func sections(query: String, feeds: [SourceSearchResult], channels: [SourceSearchResult],
                                xAccounts: [SourceSearchResult]) -> SourceSearchSections {
        let name = name(in: query)
        let exactOnly = query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@")
        let shown = channels.filter { channel in
            if channel.handle?.lowercased() == name.lowercased() { return true }
            return !exactOnly && (subscriberCount(channel.audience) ?? 0) >= minSubscribers
        }
        let channelKeys = Set(channels.map { feedKey($0.feedUrl) })
        let rest = feeds.filter { feed in
            if channelKeys.contains(feedKey(feed.feedUrl)) { return false }
            if let site = feed.siteUrl.flatMap({ URLComponents(string: $0)?.host }), PageScraping.isXHost(site) { return false }
            return (shown.isEmpty && xAccounts.isEmpty) || matches(feed, query: name)
        }

        var out = SourceSearchSections()
        out.x = xAccounts
        out.youtube = shown + rest.filter { $0.kind == .youtube }
        out.podcasts = rest.filter { $0.kind == .podcast }
        out.sites = rest.filter { $0.kind != .youtube && $0.kind != .podcast }
        out.all = Array(out.x.prefix(allAccounts)) + out.youtube.prefix(allAccounts)
        for i in 0..<max(out.sites.count, out.podcasts.count) {
            if i < out.sites.count { out.all.append(out.sites[i]) }
            if i < out.podcasts.count { out.all.append(out.podcasts[i]) }
        }
        return out
    }

    /// How many X accounts and how many channels `all` shows.
    static let allAccounts = 3
}
