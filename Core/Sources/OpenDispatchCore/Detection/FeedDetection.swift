import Foundation

/// User-facing failure from feed detection (shown in the Add Source dialog). Port of the `Error`
/// messages thrown by src/lib/feed-detect.ts.
public struct FeedDetectionError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Pure helpers from src/lib/feed-detect.ts (no network). Public so the UI and tests can reuse them.
public enum FeedDetection {
    /// Fetch timeout for every detection request (TIMEOUT = 15 s).
    public static let timeout: TimeInterval = 15

    /// `https://www.youtube.com/feeds/videos.xml?channel_id=<id>`
    public static func youtubeFeedURL(channelID id: String) -> String {
        "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"
    }

    /// youtubeChannelIdFromUrl: the `UC…` id from a `/channel/UC…` path.
    public static func youtubeChannelID(fromURL url: String) -> String? {
        guard let path = URLComponents(string: url)?.percentEncodedPath else { return nil }
        guard let m = path.prefixMatch(of: #/\/channel\/(UC[A-Za-z0-9_\-]{22})/#) else { return nil }
        return String(m.1)
    }

    /// isYoutubeUrl: youtube.com or any subdomain of it.
    public static func isYouTubeURL(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The page's own channel: the canonical `/channel/UC…` link, then `"externalId":"UC…"`, then
    /// `channel_id=UC…` (its RSS link), then `"channelId":"UC…"` (a watch page's owner). A channel page's first
    /// `"channelId"` can be a featured channel (@Fireship's is Beyond Fireship), so it comes last.
    public static func findChannelID(inHTML html: String) -> String? {
        if let m = html.firstMatch(of: #/rel="canonical" href="https?://(?:www\.)?youtube\.com/channel/(UC[A-Za-z0-9_\-]{22})"/#) { return String(m.1) }
        if let m = html.firstMatch(of: #/"externalId":"(UC[A-Za-z0-9_\-]{22})"/#) { return String(m.1) }
        if let m = html.firstMatch(of: #/channel_id=(UC[A-Za-z0-9_\-]{22})/#) { return String(m.1) }
        if let m = html.firstMatch(of: #/"channelId":"(UC[A-Za-z0-9_\-]{22})"/#) { return String(m.1) }
        return nil
    }

    /// findAlternateFeeds: absolute URLs of `<link rel="alternate" type="application/(rss|atom)+xml" href>`
    /// tags, in document order, resolved against `base`.
    public static func findAlternateFeeds(html: String, base: String) -> [String] {
        let baseURL = URL(string: base)
        var out: [String] = []
        for tagMatch in html.matches(of: #/<link\b[^>]*>/#.ignoresCase().matchingSemantics(.unicodeScalar)) {
            let tag = String(tagMatch.0)
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard let href = attribute("href", in: tag) else { continue }
            let rels = rel.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard rels.contains("alternate"), type.contains(#/application\/(rss|atom)\+xml/#) else { continue }
            let cleaned = href.replacingOccurrences(of: "&amp;", with: "&")
            if let u = URL(string: cleaned, relativeTo: baseURL)?.absoluteURL,
               let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                out.append(u.absoluteString)
            }
        }
        return out
    }

    /// looksLikeFeed: `<rss`, `<feed` or `<rdf:RDF` within the first 2000 characters.
    public static func looksLikeFeed(_ text: String) -> Bool {
        let head = String(text.prefix(2000)).lowercased()
        return head.contains(#/<rss\b|<feed\b|<rdf:rdf\b/#)
    }

    /// siteFrom: the origin (`scheme://host[:port]`) of `link`, else of `fallback`, else `fallback`.
    public static func siteOrigin(_ link: String?, fallback: String) -> String {
        origin(of: link ?? fallback) ?? fallback
    }

    /// `new URL(u).origin`, or nil when `u` has no scheme and host.
    public static func origin(of u: String) -> String? {
        guard let c = URLComponents(string: u), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty
        else { return nil }
        var s = "\(scheme)://\(host)"
        if let port = c.port, !(scheme == "https" && port == 443) && !(scheme == "http" && port == 80) { s += ":\(port)" }
        return s
    }

    /// applePodcastId: the numeric show id in a podcasts.apple.com / itunes.apple.com URL.
    public static func applePodcastID(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased(),
              host == "podcasts.apple.com" || host == "itunes.apple.com" else { return nil }
        if let m = c.percentEncodedPath.firstMatch(of: #/\/id(\d+)(?:\/|$)/#) { return String(m.1) }
        if let id = c.queryItems?.first(where: { $0.name == "id" })?.value,
           !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) { return id }
        return nil
    }

    /// YouTube's channel feeds fail at times for channels that exist, so they get a few tries.
    public static let youtubeFeedAttempts = 4
    public static let youtubeFeedRetryDelay: Duration = .milliseconds(400)

    /// The feed of a Reddit community or user page; nil for a post or any other address.
    public static func redditFeedURL(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased(),
              host == "reddit.com" || host.hasSuffix(".reddit.com"), !RedditPages.isThread(url) else { return nil }
        let segments = c.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        switch segments[0].lowercased() {
        case "r": return "\(RedditPages.origin)/r/\(segments[1])/.rss"
        case "user", "u": return "\(RedditPages.origin)/user/\(segments[1])/.rss"
        default: return nil
        }
    }

    /// The name of a place whose public pages have no feed or posts to follow, for a link to one of them.
    public static func noFeedPlace(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        let places = ["instagram.com": "Instagram", "threads.net": "Threads", "threads.com": "Threads", "tiktok.com": "TikTok",
                      "linkedin.com": "LinkedIn", "facebook.com": "Facebook", "twitch.tv": "Twitch"]
        return places.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value
    }

    /// isSpotifyShowUrl: open/podcasters.spotify.com show or episode pages.
    public static func isSpotifyShowURL(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased(),
              host == "open.spotify.com" || host == "podcasters.spotify.com" else { return false }
        return c.percentEncodedPath.contains(#/\/(show|episode)\//#)
    }

    /// The URL a page-kind source is stored under: canonicalUrl (origin + path without trailing
    /// slashes, "/" when empty) plus the query; the fragment is dropped.
    public static func pageSourceURL(_ url: String) -> String {
        guard let c = URLComponents(string: url), let origin = origin(of: url) else { return url }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        let query = c.percentEncodedQuery.map { $0.isEmpty ? "" : "?\($0)" } ?? ""
        return origin + path + query
    }

    /// The hostname (as the web's `new URL(u).hostname`), or `u` itself.
    static func hostname(_ u: String) -> String {
        URLComponents(string: u)?.host?.lowercased() ?? u
    }

    /// `\b<name>\s*=\s*["']([^"']+)["']` inside a tag (case-insensitive).
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let re = try? Regex("\\b\(name)\\s*=\\s*[\"']([^\"']+)[\"']").ignoresCase(),
              let m = try? re.firstMatch(in: tag), m.output.count > 1,
              let sub = m.output[1].substring else { return nil }
        return String(sub)
    }
}
