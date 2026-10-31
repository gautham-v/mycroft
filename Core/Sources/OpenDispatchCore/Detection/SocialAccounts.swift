import Foundation
import SwiftSoup

/// Finds accounts on the other places "Add sources" searches, each landing on its own. All without an account: Bluesky's public AppView
/// and its RSS feeds, a Mastodon server's search and each profile's `.rss`, Reddit's community search read in the hidden web view
/// (`DiscussionWeb`, Reddit refuses plain requests to it) with each community's `.rss`. Instagram's profile preview names an account, but
/// its public pages list no posts, so it can only be shown and never followed.
public protocol SocialAccountSearching: Sendable {
    func bluesky(_ query: String) async throws -> [SourceSearchResult]
    func blueskyProfile(handle: String) async throws -> SourceSearchResult?
    func mastodon(_ query: String) async throws -> [SourceSearchResult]
    func reddit(_ query: String) async throws -> [SourceSearchResult]
    func instagramProfile(handle: String) async throws -> SourceSearchResult?
}

public struct DefaultSocialAccounts: SocialAccountSearching {
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async throws -> (Data, HTTPURLResponse)
    typealias RedditPage = @Sendable (_ path: String) async throws -> String

    static let timeout: TimeInterval = 8
    static let limit = 6
    static let appView = "https://public.api.bsky.app/xrpc"
    /// The largest server, whose search also finds accounts on other servers it knows of.
    static let mastodonServer = "https://mastodon.social"

    let fetch: Fetch
    let redditPage: RedditPage

    public init() {
        self.init(fetch: { url, headers in
            try await HTTP.fetch(url, timeout: Self.timeout, headers: headers)
        }, redditPage: { path in
            #if canImport(WebKit)
            return try await DiscussionWeb.shared.redditHTML(path)
            #else
            throw DiscussionError.unavailable
            #endif
        })
    }

    /// Tests inject a fake network.
    init(fetch: @escaping Fetch, redditPage: @escaping RedditPage) {
        self.fetch = fetch
        self.redditPage = redditPage
    }

    private func json(_ url: String) async throws -> Data {
        let (data, res) = try await fetch(url, ["Accept": "application/json"])
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return data
    }

    private static func encoded(_ q: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;@")
        return q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
    }

    // MARK: Bluesky

    private struct BlueskyActors: Decodable {
        struct Actor: Decodable {
            let did: String
            let handle: String
            let displayName: String?
            let avatar: String?
            let followersCount: Int?
        }
        let actors: [Actor]?
        let profiles: [Actor]?
    }

    public func bluesky(_ query: String) async throws -> [SourceSearchResult] {
        let found = try JSONDecoder().decode(BlueskyActors.self, from: try await json(
            "\(Self.appView)/app.bsky.actor.searchActors?q=\(Self.encoded(SourceSearch.name(in: query)))&limit=\(Self.limit)"))
        let dids = (found.actors ?? []).map(\.did)
        guard !dids.isEmpty else { return [] }
        // A search answer has no follower counts; the profiles do.
        let actors = dids.map { "actors=\(Self.encoded($0))" }.joined(separator: "&")
        let profiles = try JSONDecoder().decode(BlueskyActors.self, from: try await json("\(Self.appView)/app.bsky.actor.getProfiles?\(actors)"))
        return (profiles.profiles ?? []).map(Self.blueskyResult)
    }

    public func blueskyProfile(handle: String) async throws -> SourceSearchResult? {
        let profiles = try JSONDecoder().decode(BlueskyActors.self, from: try await json(
            "\(Self.appView)/app.bsky.actor.getProfiles?actors=\(Self.encoded(handle))"))
        return profiles.profiles?.first.map(Self.blueskyResult)
    }

    private static func blueskyResult(_ a: BlueskyActors.Actor) -> SourceSearchResult {
        let name = a.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SourceSearchResult(title: name.isEmpty ? a.handle : name, subtitle: "Bluesky", feedUrl: "https://bsky.app/profile/\(a.did)/rss",
                                  siteUrl: "https://bsky.app/profile/\(a.handle)", kind: .rss, imageUrl: a.avatar, handle: a.handle,
                                  audience: a.followersCount.map(XAccounts.followers), place: .bluesky)
    }

    // MARK: Mastodon

    private struct MastodonSearch: Decodable {
        struct Account: Decodable {
            let acct: String
            let display_name: String?
            let url: String?
            let avatar_static: String?
            let followers_count: Int?
            let bot: Bool?
        }
        let accounts: [Account]?
    }

    public func mastodon(_ query: String) async throws -> [SourceSearchResult] {
        let found = try JSONDecoder().decode(MastodonSearch.self, from: try await json(
            "\(Self.mastodonServer)/api/v2/search?q=\(Self.encoded(SourceSearch.name(in: query)))&type=accounts&limit=\(Self.limit)"))
        return (found.accounts ?? []).compactMap { a in
            guard a.bot != true, let url = a.url, url.contains("/@") else { return nil }
            let name = a.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SourceSearchResult(title: name.isEmpty ? a.acct : name, subtitle: "Mastodon", feedUrl: url + ".rss", siteUrl: url, kind: .rss,
                                      imageUrl: a.avatar_static, handle: a.acct, audience: a.followers_count.map(XAccounts.followers), place: .mastodon)
        }
    }

    // MARK: Reddit

    public func reddit(_ query: String) async throws -> [SourceSearchResult] {
        let q = SourceSearch.name(in: query)
        let bare = q.lowercased().hasPrefix("r/") ? String(q.dropFirst(2)) : q
        return Self.communities(inSearch: try await redditPage("/subreddits/search?q=\(Self.encoded(bare))"))
    }

    /// A community as a result, by its name without "r/".
    public static func community(_ name: String, about: String? = nil) -> SourceSearchResult {
        let site = "\(RedditPages.origin)/r/\(name)/"
        return SourceSearchResult(title: "r/\(name)", subtitle: about?.isEmpty == false ? about! : "Community", feedUrl: site + ".rss", siteUrl: site,
                                  kind: .rss, handle: name, place: .reddit)
    }

    /// The communities on a search page, leaving out people's profiles and adult communities.
    static func communities(inSearch html: String) -> [SourceSearchResult] {
        guard let doc = try? SwiftSoup.parse(html, RedditPages.origin) else { return [] }
        let things = (try? doc.select(".thing.subreddit").array()) ?? []
        let out = things.compactMap { thing -> SourceSearchResult? in
            guard (try? thing.hasClass("over18")) != true, let title = try? thing.select("a.title").first()?.text() else { return nil }
            let parts = title.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, first.hasPrefix("r/") else { return nil }
            return community(String(first.dropFirst(2)), about: parts.count > 1 ? parts[1] : nil)
        }
        return Array(out.prefix(limit))
    }

    // MARK: Instagram

    private static let instagramTitle = ExtractionDOM.Pattern(#"^(.*) \(@([^)]+)\)"#)
    private static let instagramCount = ExtractionDOM.Pattern(#"^([\d.,]+[KMB]?) Followers"#)

    public func instagramProfile(handle: String) async throws -> SourceSearchResult? {
        let (data, res) = try await fetch("https://www.instagram.com/\(handle)/", SocialPosts.crawlerHeaders)
        guard (200..<300).contains(res.statusCode) else { return nil }
        return Self.instagramProfile(html: HTTP.text(data, response: res))
    }

    /// The account in a profile's preview tags.
    static func instagramProfile(html: String) -> SourceSearchResult? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        func meta(_ property: String) -> String? {
            let value = try? doc.select("meta[property=\(property)]").first()?.attr("content")
            return value?.isEmpty == false ? value : nil
        }
        guard let title = meta("og:title"), let m = instagramTitle.firstMatch(title), let name = m[1], let handle = m[2] else { return nil }
        let count = meta("og:description").flatMap { instagramCount.firstMatch($0)?[1] ?? nil }
        let url = "https://www.instagram.com/\(handle)/"
        return SourceSearchResult(title: name, subtitle: "Instagram", feedUrl: url, siteUrl: url, kind: .page, imageUrl: meta("og:image"),
                                  handle: handle, audience: count.map { "\($0) followers" }, place: .instagram)
    }
}
