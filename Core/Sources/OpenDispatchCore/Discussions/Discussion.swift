import Foundation

/// Where a post and its comments live. Reddit and X are read through a hidden web view (`DiscussionWeb`), X only once the
/// user has signed in to it in the app; the others through their open APIs.
public enum DiscussionPlace: String, Sendable, CaseIterable, Hashable, Codable {
    case reddit, x, bluesky, hackerNews, youtube

    public var name: String {
        switch self {
        case .reddit: "Reddit"
        case .x: "X"
        case .bluesky: "Bluesky"
        case .hackerNews: "Hacker News"
        case .youtube: "YouTube"
        }
    }

    /// Explore searches these, in this order.
    public static let searched: [DiscussionPlace] = [.reddit, .x, .bluesky, .hackerNews]

    /// The place whose thread `url` is: a Reddit post, a post on X or Bluesky, a Hacker News item, a YouTube video. Nil
    /// for anything else (an article, a subreddit, a profile).
    public static func thread(of url: String) -> DiscussionPlace? {
        if RedditPages.isThread(url) { return .reddit }
        if TweetExtraction.tweetURL.test(url) { return .x }
        if SocialPosts.blueskyURL.test(url) { return .bluesky }
        if HackerNewsThreads.itemID(url) != nil { return .hackerNews }
        if OpenedLinks.youTubeVideoID(url) != nil { return .youtube }
        return nil
    }
}

/// A post Explore found: a Reddit thread, a post on X or Bluesky, a Hacker News story. Opening it stores it as an opened
/// link (`OpenDispatchServices.openExplorePost`) that the reader shows with its comments.
public struct DiscussionPost: Sendable, Hashable, Identifiable {
    public var place: DiscussionPlace
    /// The thread's canonical address, which the opened item is stored under.
    public var url: String
    /// A headline (Reddit, Hacker News); posts on X and Bluesky have only `text`.
    public var title: String?
    /// The post's text, plain, for X and Bluesky (Reddit and Hacker News leave it out of their search results).
    public var text: String?
    /// The display name, and the handle without its "@" (X, Bluesky) or the "u/" account (Reddit).
    public var author: String?
    public var handle: String?
    /// "r/LoveIsBlindNetflix".
    public var community: String?
    /// The author's avatar (X, Bluesky) or the community's icon (Reddit).
    public var avatarUrl: String?
    public var published: Date?
    /// Votes (Reddit), likes (X, Bluesky) or points (Hacker News).
    public var score: Int?
    public var comments: Int?
    public var thumbnailUrl: String?
    /// The page a link post points to (a Hacker News story's article).
    public var link: String?

    public var id: String { place.rawValue + ":" + url }

    public init(place: DiscussionPlace, url: String, title: String? = nil, text: String? = nil, author: String? = nil,
                handle: String? = nil, community: String? = nil, avatarUrl: String? = nil, published: Date? = nil,
                score: Int? = nil, comments: Int? = nil, thumbnailUrl: String? = nil, link: String? = nil) {
        self.place = place
        self.url = url
        self.title = title
        self.text = text
        self.author = author
        self.handle = handle
        self.community = community
        self.avatarUrl = avatarUrl
        self.published = published
        self.score = score
        self.comments = comments
        self.thumbnailUrl = thumbnailUrl
        self.link = link
    }

    /// The headline, or the post's first line (posts on X and Bluesky), as a list row and the opened item read.
    public var headline: String {
        if let title, !title.isEmpty { return title }
        let line = (text ?? "").split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if !line.isEmpty { return ScrapingText.clip(line, 140) ?? line }
        return handle.map { "Post by @\($0) on \(place.name)" } ?? "\(place.name) post"
    }
}

/// One comment of a thread. Threads arrive flattened in reading order, each comment with its depth.
public struct DiscussionComment: Sendable, Hashable, Identifiable {
    public var id: String
    public var author: String
    public var avatarUrl: String?
    public var body: RichText
    public var published: Date?
    /// Votes, likes or points; nil where the place doesn't show them (Hacker News comments).
    public var score: Int?
    /// 0 for a reply to the post.
    public var depth: Int
    /// A link to the comment on its site.
    public var url: String?
    /// The post's author wrote it.
    public var byAuthor: Bool

    public init(id: String, author: String, avatarUrl: String? = nil, body: RichText, published: Date? = nil, score: Int? = nil,
                depth: Int, url: String? = nil, byAuthor: Bool = false) {
        self.id = id
        self.author = author
        self.avatarUrl = avatarUrl
        self.body = body
        self.published = published
        self.score = score
        self.depth = depth
        self.url = url
        self.byAuthor = byAuthor
    }
}

/// Comments not loaded yet, where they would go: more replies to the comment above (at that comment's depth + 1) or the
/// next page of replies to the post (depth 0). `token` is the place's own (a Reddit partial, a YouTube continuation).
public struct DiscussionMore: Sendable, Hashable, Identifiable {
    public var token: String
    public var depth: Int
    /// How many, when the place says.
    public var count: Int?

    public var id: String { "more:" + token }

    public init(token: String, depth: Int, count: Int? = nil) {
        self.token = token
        self.depth = depth
        self.count = count
    }
}

/// A row of a thread: a comment, or a place to load more.
public enum DiscussionEntry: Sendable, Hashable, Identifiable {
    case comment(DiscussionComment)
    case more(DiscussionMore)

    public var id: String {
        switch self {
        case .comment(let c): c.id
        case .more(let m): m.id
        }
    }

    public var depth: Int {
        switch self {
        case .comment(let c): c.depth
        case .more(let m): m.depth
        }
    }

    public var comment: DiscussionComment? {
        if case .comment(let c) = self { return c }
        return nil
    }

    /// Entries loaded for a `DiscussionMore` at `depth`, shifted so the shallowest sits there (a place may number the
    /// loaded replies from 0).
    static func placed(_ entries: [DiscussionEntry], at depth: Int) -> [DiscussionEntry] {
        guard let least = entries.map(\.depth).min(), least != depth else { return entries }
        let shift = depth - least
        return entries.map { entry in
            switch entry {
            case .comment(var c):
                c.depth += shift
                return .comment(c)
            case .more(var m):
                m.depth += shift
                return .more(m)
            }
        }
    }
}

/// The comments of a post as first loaded.
public struct DiscussionThread: Sendable, Hashable {
    public var entries: [DiscussionEntry]
    /// The post's comment count, when the place says.
    public var total: Int?

    public init(entries: [DiscussionEntry], total: Int? = nil) {
        self.entries = entries
        self.total = total
    }
}

public enum DiscussionError: Error, LocalizedError, Equatable {
    /// X shows nothing to a visitor who isn't signed in.
    case signInRequired(DiscussionPlace)
    /// The place refused the request (Reddit's block page, a rate limit).
    case blocked(DiscussionPlace)
    case unavailable
    case notFound

    public var errorDescription: String? {
        switch self {
        case .signInRequired(let place): "Sign in to \(place.name) to see posts and replies"
        case .blocked(let place): "\(place.name) didn\u{2019}t answer. Try again in a minute."
        case .unavailable: "Comments can\u{2019}t be loaded here"
        case .notFound: "This post is gone"
        }
    }
}

/// Explore's post search and the reader's comments. `DefaultDiscussions` is the live one.
public protocol DiscussionLoading: Sendable {
    /// Posts about `query` on one place, most relevant first. Throws `DiscussionError.signInRequired` for X when the user
    /// hasn't signed in.
    func search(_ place: DiscussionPlace, query: String) async throws -> [DiscussionPost]
    /// The comments of the thread at `url` (`DiscussionPlace.thread(of:)` says which).
    func comments(for url: String) async throws -> DiscussionThread
    /// What a `DiscussionMore` of that thread stands for, to put in its place.
    func more(_ more: DiscussionMore, in url: String) async throws -> [DiscussionEntry]
}

enum DiscussionDates {
    private static let fraction = ExtractionDOM.Pattern(#"(\.\d{3})\d+"#)
    private static let zone = ExtractionDOM.Pattern(#"([+-]\d{2})(\d{2})$"#)

    /// ISO 8601 as the places write it, including Reddit's "2026-10-28T10:44:14.463000+0000" (microseconds, and a zone
    /// without its colon).
    static func parse(_ value: String?) -> Date? {
        guard var s = value?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = ISO8601.date(from: s) { return d }
        s = fraction.replacing(s, with: "$1")
        s = s.hasSuffix("+0000") ? String(s.dropLast(5)) + "Z" : zone.replacing(s, with: "$1:$2")
        return ISO8601.date(from: s)
    }
}
