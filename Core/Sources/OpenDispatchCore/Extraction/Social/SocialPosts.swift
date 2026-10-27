import Foundation

/// Posts on Bluesky, Mastodon, LinkedIn, Threads and Instagram, found by address and read from each network's
/// public data without an account: Bluesky's public AppView, a Mastodon server's status API, LinkedIn's public
/// post page, and for Threads and Instagram the preview tags their pages give link-preview crawlers. Posts on X
/// have their own path (`TweetExtraction`). The reader shows them all with the same x-* post markup.
enum SocialPosts {
    typealias P = ExtractionDOM.Pattern

    /// One GET with these headers (the timeout is the caller's): the body and final response (its `url` is the
    /// address after redirects), or nil when the request failed.
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async -> (Data, HTTPURLResponse)?

    static let jsonHeaders = ["Accept": "application/json"]

    /// Threads and Instagram serve their post pages' data only to link-preview crawlers; a browser gets the login wall.
    static let crawlerHeaders = [
        "User-Agent": "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
        "Accept": "text/html",
    ]

    /// Mastodon: `https://<instance>/@user/<numeric status id>`, also `@user@other.instance` as the instance names a remote account.
    static let mastodonURL = P(#"^https?://([^/@?#]+)/(@[^/?#]+)/(\d+)/?(?:[?#]|$)"#, caseInsensitive: true)
    static let blueskyURL = P(#"^https?://(?:www\.)?bsky\.app/profile/([^/?#]+)/post/([A-Za-z0-9]+)"#, caseInsensitive: true)
    /// A LinkedIn post page or its short link. Articles (`/pulse/`) and profiles are not posts.
    static let linkedinURL = P(#"^https?://(?:[a-z]{2,3}\.|www\.)?(?:linkedin\.com/(?:posts/|feed/update/)|lnkd\.in/)"#, caseInsensitive: true)
    static let threadsURL = P(#"^https?://(?:www\.)?threads\.(?:com|net)/@([^/?#]+)/post/([A-Za-z0-9_-]+)"#, caseInsensitive: true)
    static let instagramURL = P(#"^https?://(?:www\.)?instagram\.com/(?:([^/?#]+)/)?(p|reel|tv)/([A-Za-z0-9_-]+)"#, caseInsensitive: true)

    /// The network whose post `url` is, or nil (including for X, whose posts are `TweetExtraction`'s).
    static func network(of url: String) -> SocialPost.Network? {
        if blueskyURL.test(url) { return .bluesky }
        if linkedinURL.test(url) { return .linkedin }
        if threadsURL.test(url) { return .threads }
        if instagramURL.test(url), instagramUser(url) != "explore" { return .instagram }
        if mastodonURL.test(url) { return .mastodon }
        return nil
    }

    /// The account in an Instagram address of the form instagram.com/user/p/id.
    static func instagramUser(_ url: String) -> String? {
        instagramURL.firstMatch(url)?[1] ?? nil
    }

    /// The post at `url`, or nil when it isn't a post of these networks or can't be read.
    static func load(url: String, fetch: Fetch) async -> SocialPost? {
        switch network(of: url) {
        case .bluesky: await BlueskyPost.load(url: url, fetch: fetch)
        case .mastodon: await MastodonPost.load(url: url, fetch: fetch)
        case .linkedin: await LinkedInPost.load(url: url, fetch: fetch)
        case .threads, .instagram: await PreviewTagPost.load(url: url, fetch: fetch)
        case nil: nil
        }
    }

    /// The reader content for a post of these networks; nil to let the generic extractor try.
    static func extract(url: String, fetch: Fetch) async -> ExtractResult? {
        await load(url: url, fetch: fetch)?.render()
    }

    /// The opened-link item for a post of these networks, titled by its first paragraph. A Threads or Instagram
    /// post that can't be read (they gate on login) still gets a title naming its author rather than the wall's;
    /// nil for any other address, or another network's unreadable post, so the page's own metadata is used.
    static func item(url: String, fetch: Fetch, now: Date = Date()) async -> ParsedItem? {
        guard let network = network(of: url) else { return nil }
        if let post = await load(url: url, fetch: fetch) { return post.item(now: now) }
        guard network == .threads || network == .instagram else { return nil }
        return ParsedItem(guid: url, url: url, title: unreadableTitle(url, network: network), publishedAt: now)
    }

    /// "Post by @user on Instagram", from the address.
    static func unreadableTitle(_ url: String, network: SocialPost.Network) -> String {
        let user = network == .threads ? threadsURL.firstMatch(url)?[1] ?? nil : instagramUser(url)
        return user.map { "Post by @\($0) on \(network.name)" } ?? "\(network.name) post"
    }

    /// ISO 8601 from a network's JSON.
    static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(ISO8601.date(from:))
    }
}
