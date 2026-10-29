import Foundation
import GRDB

/// How a source is fetched. Mirrors `source_kind` in src/db/schema.ts.
/// - rss: an RSS/Atom feed. - youtube: a channel's videos.xml feed.
/// - page: a listing page with no feed, scraped for article links. - podcast: an RSS feed of audio episodes.
/// - topic: a followed keyword search (`Topic`), whose items are a mix of articles, discussions, videos and
///   episodes from places outside the subscriptions. How one of its items reads or plays is decided per item
///   (`Source.shown(for:)` rewrites the kind of a list row), never from this value.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Hashable, DatabaseValueConvertible {
    case rss, youtube, page, podcast, topic
}

/// Derived from kind + url: how a source's items read (src/lib/queries.ts `sourceType`).
public enum SourceType: String, Codable, Sendable, CaseIterable, Hashable {
    case article, post, video, podcast

    public init(kind: SourceKind, url: String) {
        switch kind {
        case .youtube: self = .video
        case .podcast: self = .podcast
        case .rss, .page, .topic: self = PostSource.isPostURL(url) ? .post : .article
        }
    }
}

/// Legacy `group` values (the column is free text; these are the ones the app writes).
public enum SourceGroup {
    public static let labs = "labs"
    public static let blogs = "blogs"
    public static let news = "news"
    public static let aggregator = "aggregator"
    public static let youtube = "youtube"
    public static let podcast = "podcast"
    public static let topics = "topics"
}

/// Post sources (X/Twitter, Bluesky, Threads, Mastodon profiles). Port of POST_SOURCE_RE in
/// src/lib/folders.ts: `^https?://(www\.|mobile\.)?(x\.com|twitter\.com|bsky\.app|threads\.net|mastodon\.[a-z]+)/`, case-insensitive.
public enum PostSource {
    private static let hosts: Set<String> = ["x.com", "twitter.com", "bsky.app", "threads.net"]

    public static func isPostURL(_ url: String) -> Bool {
        let s = url.lowercased()
        let rest: Substring
        if s.hasPrefix("https://") { rest = s.dropFirst(8) }
        else if s.hasPrefix("http://") { rest = s.dropFirst(7) }
        else { return false }
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let host = rest[rest.startIndex..<slash]
        if matchesHost(host) { return true }
        for prefix in ["www.", "mobile."] where host.hasPrefix(prefix) {
            if matchesHost(host.dropFirst(prefix.count)) { return true }
        }
        return false
    }

    private static func matchesHost(_ host: Substring) -> Bool {
        if hosts.contains(String(host)) { return true }
        if host.hasPrefix("mastodon.") {
            let tld = host.dropFirst("mastodon.".count)
            return !tld.isEmpty && tld.allSatisfy { $0 >= "a" && $0 <= "z" }
        }
        return false
    }
}
