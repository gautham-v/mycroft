import Foundation

/// What a topic's refresh found, place by place.
public struct TopicSearchOutcome: Sendable, Hashable {
    /// The matches, newest first, ready to store (before dedupe and the retention cut).
    public var items: [ParsedItem]
    /// The places that were searched.
    public var searched: [TopicPlace]
    /// The places that failed, with a readable reason each. A place with several providers (Hacker News and
    /// Reddit) fails only when they all did.
    public var failures: [TopicPlace: String]

    public init(items: [ParsedItem] = [], searched: [TopicPlace] = [], failures: [TopicPlace: String] = [:]) {
        self.items = items
        self.searched = searched
        self.failures = failures
    }

    /// Every searched place failed: the topic records an error. One that works makes it a success, with whatever it found.
    public var allFailed: Bool { !searched.isEmpty && searched.allSatisfy { failures[$0] != nil } }

    /// The failure to record: the first failed place's, in the order News, Hacker News, Reddit, X, Bluesky, Media.
    public var errorMessage: String? {
        TopicPlace.allCases.compactMap { failures[$0] }.first
    }
}

/// The user's subscriptions as a topic sees them, to tell a notable match from the rest: it comes from a site, a
/// channel or a show the user follows.
public struct TopicSubscriptions: Sendable, Hashable {
    /// Hosts of subscribed websites (feeds and scraped pages), without "www.".
    var hosts: Set<String> = []
    /// Titles of subscribed sources, folded: the publisher, channel or show name a result carries.
    var titles: Set<String> = []
    /// YouTube channel ids of subscribed channels.
    var channelIDs: Set<String> = []

    public static let empty = TopicSubscriptions()

    /// Platforms whose subscriptions say nothing about a link to them: following a channel is not following youtube.com.
    private static let platformHosts: Set<String> = [
        "youtube.com", "youtu.be", "reddit.com", "news.ycombinator.com", "ycombinator.com", "apple.com", "podcasts.apple.com",
        "x.com", "twitter.com", "bsky.app", "threads.net", "medium.com", "substack.com", "github.com", "opendispatch.app",
    ]

    public init() {}

    public init(sources: [Source]) {
        for s in sources where !s.isTopic && !s.isOpenedLinks {
            let title = TopicMatcher.fold(s.title)
            if !title.isEmpty { titles.insert(title) }
            switch s.kind {
            case .youtube:
                if let id = Self.channelID(of: s) { channelIDs.insert(id) }
            case .rss, .page:
                let host = s.host
                if !host.isEmpty, !Self.isPlatform(host) { hosts.insert(host) }
            case .podcast, .topic:
                break
            }
        }
    }

    private static func isPlatform(_ host: String) -> Bool {
        platformHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The `UC…` id in a channel source's address or feed address.
    private static func channelID(of s: Source) -> String? {
        for candidate in [s.url, s.feedUrl] {
            guard let c = URLComponents(string: candidate) else { continue }
            if let id = c.queryItems?.first(where: { $0.name == "channel_id" })?.value, id.hasPrefix("UC") { return id }
            if let last = c.path.split(separator: "/").last, last.hasPrefix("UC"), last.count == 24 { return String(last) }
        }
        return nil
    }

    /// The site's host is a subscribed website (or a subdomain of one, or the other way round).
    func follows(host: String) -> Bool {
        let h = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        guard !h.isEmpty, !Self.isPlatform(h) else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) || $0.hasSuffix("." + h) }
    }

    /// A publisher, channel or show of this name is subscribed.
    func follows(name: String) -> Bool {
        let n = TopicMatcher.fold(name)
        return !n.isEmpty && titles.contains(n)
    }

    func follows(channelID: String?) -> Bool {
        channelID.map(channelIDs.contains) ?? false
    }
}

/// Which matches count as notable (the Show: Notable only switch): a Hacker News story with 100 points or
/// more, a Reddit post with a score of 200 or more, a post on X with 1,000 likes or on Bluesky with 100, or anything from a
/// site, channel or show the user follows.
public enum TopicNotability {
    public static let hackerNewsPoints = 100
    public static let redditScore = 200
    public static let xLikes = 1000
    public static let blueskyLikes = 100
}

/// Searches the places outside the user's subscriptions for a topic. Behind a protocol so refresh tests fake it.
public protocol TopicSearching: Sendable {
    /// Searches the places `options` turns on, concurrently. Never throws: a place that fails is in `failures`.
    /// Matches are filtered by the keyword in the title and the leave-out words (`TopicMatcher`), the user's languages, and
    /// non-notable ones when `notableOnly`.
    func search(_ options: TopicOptions, subscriptions: TopicSubscriptions, now: Date) async -> TopicSearchOutcome

    /// The languages the search keeps; a refresh also removes stored items in any other.
    var languages: TopicLanguages { get }

    /// Points and comments now of Hacker News stories already stored, keyed by story id ("50276099", the guid without "hn:").
    /// Stories that can't be read are left out; a failure is silent, the stored numbers stay.
    func hackerNewsStats(ids: [String]) async -> [String: TopicHackerNewsStats]
}

/// A Hacker News story's current numbers.
public struct TopicHackerNewsStats: Sendable, Hashable {
    public var points: Int
    public var comments: Int
    public init(points: Int, comments: Int) {
        self.points = points
        self.comments = comments
    }
}

/// A topic whose every searched place failed, thrown by a refresh so the topic records the reason as its last error.
public struct TopicSearchError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension TopicSearching {
    public var languages: TopicLanguages { .current }

    public func hackerNewsStats(ids: [String]) async -> [String: TopicHackerNewsStats] { [:] }

    public func search(_ options: TopicOptions, subscriptions: TopicSubscriptions = .empty) async -> TopicSearchOutcome {
        await search(options, subscriptions: subscriptions, now: Date())
    }
}
