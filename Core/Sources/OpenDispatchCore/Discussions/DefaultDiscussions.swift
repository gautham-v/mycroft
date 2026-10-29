import Foundation

/// Explore's post search and the reader's comments, place by place: Reddit and X through `DiscussionWeb` (a hidden web view;
/// X only when signed in), Bluesky, Hacker News and YouTube through their open APIs. See each place's file for how it is read.
public struct DefaultDiscussions: DiscussionLoading {
    /// GET when `body` is nil, otherwise a JSON POST.
    typealias Fetch = @Sendable (_ url: String, _ body: Data?) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 12
    /// Reddit's search over the last week finds the posts people are talking about now; with fewer than this many it looks
    /// back a month too.
    static let redditMinimum = 3
    /// How far X's pages are scrolled for more: a search, and a post's replies.
    static let xSearchScrolls = 2
    static let xReplyScrolls = 3

    let fetch: Fetch

    public init() {
        self.init(fetch: { url, body in
            var headers = ["Accept": "application/json"]
            if body != nil { headers["Content-Type"] = "application/json" }
            return try await HTTP.fetch(url, timeout: Self.timeout, method: body == nil ? "GET" : "POST", headers: headers, body: body)
        })
    }

    /// Tests inject a fake network (Reddit and X aren't reached through it).
    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    // MARK: Search

    public func search(_ place: DiscussionPlace, query: String, now: Date) async throws -> [DiscussionPost] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        switch place {
        case .reddit:
            var posts = RedditPages.posts(inSearch: try await reddit(RedditPages.searchPath(q, range: "week")))
            if posts.count < Self.redditMinimum {
                let seen = Set(posts.map(\.url))
                posts += RedditPages.posts(inSearch: try await reddit(RedditPages.searchPath(q, range: "month"))).filter { !seen.contains($0.url) }
            }
            return posts
        case .x:
            #if canImport(WebKit)
            return XPages.searchResults(inCells: try await DiscussionWeb.shared.xCells(XPages.searchURL(q), scrolls: Self.xSearchScrolls))
            #else
            throw DiscussionError.unavailable
            #endif
        case .bluesky:
            return try BlueskyThreads.posts(inSearch: try await get(BlueskyThreads.searchURL(q, now: now)))
        case .hackerNews:
            return try HackerNewsThreads.posts(inSearch: try await get(HackerNewsThreads.searchURL(q, now: now)))
        case .youtube:
            return []
        }
    }

    public func search(_ place: DiscussionPlace, query: String) async throws -> [DiscussionPost] {
        try await search(place, query: query, now: Date())
    }

    // MARK: Comments

    public func comments(for url: String) async throws -> DiscussionThread {
        switch DiscussionPlace.thread(of: url) {
        case .reddit:
            guard let canonical = RedditPages.canonicalURL(url) else { throw DiscussionError.notFound }
            return RedditPages.thread(try await reddit(String(canonical.dropFirst(RedditPages.origin.count))))
        case .x:
            #if canImport(WebKit)
            let cells = try await DiscussionWeb.shared.xCells(url, scrolls: Self.xReplyScrolls)
            return DiscussionThread(entries: XPages.replies(inCells: cells, threadURL: url))
            #else
            throw DiscussionError.unavailable
            #endif
        case .bluesky:
            guard let api = BlueskyThreads.threadURL(url) else { throw DiscussionError.notFound }
            return try BlueskyThreads.thread(try await get(api))
        case .hackerNews:
            guard let id = HackerNewsThreads.itemID(url) else { throw DiscussionError.notFound }
            return try HackerNewsThreads.thread(try await get(HackerNewsThreads.itemAPI(id: id)))
        case .youtube:
            guard let id = OpenedLinks.youTubeVideoID(url) else { throw DiscussionError.notFound }
            let watch = try await post(YouTubeComments.nextURL, YouTubeComments.body(videoID: id))
            guard let token = try YouTubeComments.commentsToken(inWatch: watch) else { return DiscussionThread(entries: []) }
            let page = try await post(YouTubeComments.nextURL, YouTubeComments.body(continuation: token))
            return DiscussionThread(entries: try YouTubeComments.entries(page, depth: 0))
        case nil:
            throw DiscussionError.unavailable
        }
    }

    public func more(_ more: DiscussionMore, in url: String) async throws -> [DiscussionEntry] {
        switch DiscussionPlace.thread(of: url) {
        case .reddit:
            let (path, cursor) = RedditPages.partial(more.token)
            let html = try await reddit(path, form: ["cursor": cursor])
            return DiscussionEntry.placed(RedditPages.moreEntries(html), at: more.depth)
        case .youtube:
            let page = try await post(YouTubeComments.nextURL, YouTubeComments.body(continuation: more.token))
            return try YouTubeComments.entries(page, depth: more.depth)
        default:
            return []
        }
    }

    // MARK: Network

    private func get(_ url: String) async throws -> Data {
        let (data, res) = try await fetch(url, nil)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return data
    }

    private func post(_ url: String, _ body: Data) async throws -> Data {
        let (data, res) = try await fetch(url, body)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return data
    }

    private func reddit(_ path: String, form: [String: String]? = nil) async throws -> String {
        #if canImport(WebKit)
        return try await DiscussionWeb.shared.redditHTML(path, form: form)
        #else
        throw DiscussionError.unavailable
        #endif
    }
}

/// Reader content for the threads the generic extractor can't read: a Reddit post (its page refuses plain requests) and a
/// Hacker News item (whose page is mostly comments, which the reader shows on its own).
enum DiscussionContent {
    /// The post's body; an empty paragraph for a post that is only a title, so the reader shows the title and comments
    /// rather than a failure. Nil when the post can't be read.
    static func extract(url: String, fetch: @escaping @Sendable (String) async throws -> Data) async -> ExtractResult? {
        switch DiscussionPlace.thread(of: url) {
        case .reddit:
            #if canImport(WebKit)
            guard let canonical = RedditPages.canonicalURL(url),
                  let html = try? await DiscussionWeb.shared.redditHTML(String(canonical.dropFirst(RedditPages.origin.count))),
                  let post = RedditPages.post(inThread: html) else { return nil }
            let lead = post.kind == .image ? post.contentHref : post.images.first
            return ExtractResult(contentHtml: RedditPages.contentHTML(post) ?? emptyBody, leadImage: lead)
            #else
            return nil
            #endif
        case .hackerNews:
            guard let id = HackerNewsThreads.itemID(url), let data = try? await fetch(HackerNewsThreads.itemAPI(id: id)),
                  let item = try? HackerNewsThreads.item(data) else { return nil }
            return ExtractResult(contentHtml: HackerNewsThreads.contentHTML(item) ?? emptyBody, leadImage: nil)
        default:
            return nil
        }
    }

    static let emptyBody = "<p></p>"

    /// The opened-link item for a Reddit post's address (its page can't be read by the link scraper); nil for anything else
    /// or a post that can't be read.
    static func redditItem(url: String, now: Date = Date()) async -> ParsedItem? {
        #if canImport(WebKit)
        guard let canonical = RedditPages.canonicalURL(url),
              let html = try? await DiscussionWeb.shared.redditHTML(String(canonical.dropFirst(RedditPages.origin.count))),
              let post = RedditPages.post(inThread: html), !post.title.isEmpty else { return nil }
        return ParsedItem(
            guid: canonical, url: canonical, title: post.title, author: post.community, publishedAt: post.published ?? now,
            thumbnailUrl: post.kind == .image ? post.contentHref : post.images.first, hnPoints: post.score, hnComments: post.comments)
        #else
        return nil
        #endif
    }
}
