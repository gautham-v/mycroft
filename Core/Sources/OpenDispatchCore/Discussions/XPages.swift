import Foundation
import SwiftSoup

/// Posts on X as its website draws them for a signed-in user. X has no open search or replies, so `DiscussionWeb` opens
/// the search or the post in a hidden web view that shares the app's X sign-in, scrolls it a little, and hands over the
/// timeline's cells (`[data-testid=cellInnerDiv]`) as HTML. Each post is an `article[data-testid=tweet]`: `User-Name`
/// holds the name and @handle, `tweetText` the text, the `time` element's link the post's address, and the action bar's
/// `role=group` label all the counts ("41 replies, 298 reposts, 5503 likes, 204 bookmarks, 328497 views").
///
/// On a post's page the post comes first, then its replies in groups; an empty cell separates the groups, and a group's
/// later posts are replies to its first (the author answering, say). A "Discover more" heading ends the replies.
///
/// X doesn't always draw a post's replies in a web view no one sees (it loads them, then leaves the list unrendered), so the
/// hidden view also keeps the answers of X's own `TweetDetail` and `SearchTimeline` requests, which are read first
/// (`replies(inDetail:)`, `posts(inTimeline:)`); the drawn cells are the fallback.
enum XPages {
    static let origin = "https://x.com"

    /// Top posts for the query, as the search page's Top tab lists them.
    static func searchURL(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(origin)/search?q=\(q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)&src=typed_query&f=top"
    }

    struct Post: Equatable {
        var url: String
        var id: String
        var name: String
        var handle: String
        var avatar: String?
        var text: RichText
        var published: Date?
        var replies: Int?
        var reposts: Int?
        var likes: Int?
        var views: Int?
        var photos: [String]
    }

    /// The posts in the cells, in order, each once.
    static func posts(inCells cells: [String]) -> [Post] {
        var seen = Set<String>()
        return cells.compactMap { cell in
            ExtractionDOM.withFragment(cell) { body in
                (try? body.select("article[data-testid=tweet]").first()).flatMap(post)
            } ?? nil
        }.filter { seen.insert($0.id).inserted }
    }

    static func searchResults(inCells cells: [String]) -> [DiscussionPost] {
        posts(inCells: cells).map { p in
            DiscussionPost(place: .x, url: p.url, text: p.text.plainText, author: p.name, handle: p.handle, avatarUrl: p.avatar,
                           published: p.published, score: p.likes, comments: p.replies, thumbnailUrl: p.photos.first)
        }
    }

    /// The replies on a post's page, grouped as the page groups them. Posts above the thread's own (the conversation it
    /// answers) and everything after "Discover more" are left out.
    static func replies(inCells cells: [String], threadURL: String) -> [DiscussionEntry] {
        let threadID = statusID(threadURL)
        var started = false
        var groupStart = true
        var seen = Set<String>()
        var out: [DiscussionEntry] = []
        var author: String?
        for cell in cells {
            let parsed: (post: Post?, ends: Bool)? = ExtractionDOM.withFragment(cell) { body in
                if let article = try? body.select("article[data-testid=tweet]").first() { return (post(article), false) }
                let heading = ((try? body.select("h2").first()?.text()) ?? "").lowercased()
                return (nil, heading.contains("discover more") || heading.contains("more posts"))
            }
            guard let parsed else { continue }
            guard let p = parsed.post else {
                if parsed.ends, started { break }
                groupStart = true
                continue
            }
            if !started {
                if p.id == threadID {
                    started = true
                    author = p.handle
                    groupStart = true
                }
                continue
            }
            guard seen.insert(p.id).inserted else { continue }
            out.append(.comment(DiscussionComment(
                id: p.id, author: p.name.isEmpty ? "@\(p.handle)" : "\(p.name) @\(p.handle)", avatarUrl: p.avatar, body: p.text,
                published: p.published, score: p.likes, depth: groupStart ? 0 : 1, url: p.url, byAuthor: p.handle == author)))
            groupStart = false
        }
        return out
    }

    // MARK: A post

    private static let statusPath = ExtractionDOM.Pattern(#"^/([^/]+)/status/(\d+)"#)

    static func statusID(_ url: String) -> String? {
        TweetExtraction.tweetURL.firstMatch(url)?[2] ?? nil
    }

    static func post(_ article: Element) -> Post? {
        let links = (try? article.select("time").array()) ?? []
        // The first time is the post's own; a quoted post's comes after.
        guard let time = links.first, let a = time.parent(), a.tagName() == "a",
              let href = try? a.attr("href"), let m = statusPath.firstMatch(href), let handle = m[1], let id = m[2] else { return nil }
        let nameBlock = try? article.select("[data-testid=User-Name]").first()
        let name = ((try? nameBlock?.select("a").first()?.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let textEl = try? article.select("[data-testid=tweetText]").first()
        let counts = (try? article.select("[role=group]").first()?.attr("aria-label")).map(counts) ?? [:]
        let photos = ((try? article.select("[data-testid=tweetPhoto] img").array()) ?? []).compactMap { try? $0.attr("src") }.filter { !$0.isEmpty }
        let avatar = (try? article.select("[data-testid=Tweet-User-Avatar] img").first()?.attr("src")).flatMap { $0.isEmpty ? nil : $0 }
        return Post(
            url: "\(origin)/\(handle)/status/\(id)", id: id, name: name.hasPrefix("@") ? "" : name, handle: handle,
            avatar: avatar, text: textEl.map { RichText.element($0, base: origin) } ?? RichText(paragraphs: []),
            published: DiscussionDates.parse(try? time.attr("datetime")), replies: counts["repl"], reposts: counts["repost"],
            likes: counts["like"], views: counts["view"], photos: photos)
    }

    private static let count = ExtractionDOM.Pattern(#"([\d,]+)\s+(repl|repost|like|bookmark|view)"#, caseInsensitive: true)

    /// "41 replies, 298 reposts, 5503 likes, 204 bookmarks, 328497 views" by its words' stems.
    static func counts(_ label: String) -> [String: Int] {
        let ns = label as NSString
        var out: [String: Int] = [:]
        for m in count.regex.matches(in: label, range: NSRange(location: 0, length: ns.length)) {
            let n = Int(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ""))
            out[ns.substring(with: m.range(at: 2)).lowercased()] = n
        }
        return out
    }

    // MARK: X's own answers

    /// A tweet as X's GraphQL answers carry it (`tweet_results.result`).
    struct Tweet {
        var id: String
        var name: String
        var handle: String
        var avatar: String?
        var text: String
        var published: Date?
        var likes: Int?
        var replies: Int?
        var photo: String?

        var url: String { "\(XPages.origin)/\(handle)/status/\(id)" }
    }

    private static let createdFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f
    }()

    /// A `tweet_results.result`; nil for a removed or withheld one (`TweetTombstone`, `TweetUnavailable`).
    static func tweet(_ value: Any?) -> Tweet? {
        guard var r = value as? [String: Any] else { return nil }
        if r["__typename"] as? String == "TweetWithVisibilityResults", let inner = r["tweet"] as? [String: Any] { r = inner }
        guard let legacy = r["legacy"] as? [String: Any], let id = (legacy["id_str"] as? String) ?? (r["rest_id"] as? String),
              let user = ((r["core"] as? [String: Any])?["user_results"] as? [String: Any])?["result"] as? [String: Any] else { return nil }
        let core = user["core"] as? [String: Any]
        let userLegacy = user["legacy"] as? [String: Any]
        guard let handle = (core?["screen_name"] as? String) ?? (userLegacy?["screen_name"] as? String) else { return nil }
        let name = (core?["name"] as? String) ?? (userLegacy?["name"] as? String) ?? handle
        let avatar = ((user["avatar"] as? [String: Any])?["image_url"] as? String) ?? (userLegacy?["profile_image_url_https"] as? String)
        let entities = legacy["entities"] as? [String: Any]
        let media = (entities?["media"] as? [[String: Any]]) ?? []
        return Tweet(
            id: id, name: name, handle: handle, avatar: avatar, text: text(r, legacy: legacy),
            published: (legacy["created_at"] as? String).flatMap(createdFormat.date(from:)),
            likes: legacy["favorite_count"] as? Int, replies: legacy["reply_count"] as? Int,
            photo: media.first { $0["type"] as? String == "photo" }?["media_url_https"] as? String)
    }

    /// The text a reader sees: a long post's whole note, else `full_text` within its display range (which leaves out the
    /// "@someone " a reply starts with and the link to its own media), with t.co links written out.
    private static func text(_ r: [String: Any], legacy: [String: Any]) -> String {
        if let note = ((((r["note_tweet"] as? [String: Any])?["note_tweet_results"] as? [String: Any])?["result"] as? [String: Any])?["text"] as? String) {
            return note
        }
        var full = (legacy["full_text"] as? String) ?? ""
        if let range = legacy["display_text_range"] as? [Int], range.count == 2 {
            let scalars = Array(full.unicodeScalars)
            let lo = max(0, min(range[0], scalars.count)), hi = max(lo, min(range[1], scalars.count))
            full = String(String.UnicodeScalarView(scalars[lo..<hi]))
        }
        let entities = legacy["entities"] as? [String: Any]
        for u in (entities?["urls"] as? [[String: Any]]) ?? [] {
            if let short = u["url"] as? String, let long = u["expanded_url"] as? String { full = full.replacingOccurrences(of: short, with: long) }
        }
        for m in (entities?["media"] as? [[String: Any]]) ?? [] {
            if let short = m["url"] as? String { full = full.replacingOccurrences(of: short, with: "") }
        }
        return full.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The timeline entries of an answer, wherever the operation keeps its `instructions`.
    private static func entries(_ data: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var instructions: [[String: Any]] = []
        func find(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let found = dict["instructions"] as? [[String: Any]] { instructions = found; return }
                for value in dict.values where instructions.isEmpty { find(value) }
            }
        }
        find(root)
        return instructions.flatMap { ($0["entries"] as? [[String: Any]]) ?? [] }
    }

    private static func itemTweet(_ item: [String: Any]?) -> Tweet? {
        tweet((item?["tweet_results"] as? [String: Any])?["result"])
    }

    /// The replies in a `TweetDetail` answer for the post `threadID`, as X ranks them: each conversation thread's first post
    /// at depth 0 and the rest of the thread (the author answering, say) at depth 1. The post itself, what it answers and
    /// "show more" cursors are left out.
    static func replies(inDetail data: Data, threadID: String?) -> [DiscussionEntry] {
        var out: [DiscussionEntry] = []
        var seen = Set<String>()
        var author: String?
        for entry in entries(data) {
            let id = entry["entryId"] as? String ?? ""
            let content = entry["content"] as? [String: Any]
            if id.hasPrefix("tweet-") {
                if let t = itemTweet(content?["itemContent"] as? [String: Any]), t.id == threadID { author = t.handle }
                continue
            }
            guard id.hasPrefix("conversationthread-") else { continue }
            let items = (content?["items"] as? [[String: Any]]) ?? []
            var depth = 0
            for item in items {
                guard let t = itemTweet((item["item"] as? [String: Any])?["itemContent"] as? [String: Any]), t.id != threadID,
                      seen.insert(t.id).inserted else { continue }
                out.append(.comment(DiscussionComment(
                    id: t.id, author: "\(t.name) @\(t.handle)", avatarUrl: t.avatar, body: RichText.plain(t.text), published: t.published,
                    score: t.likes, depth: depth, url: t.url, byAuthor: t.handle == author)))
                depth = 1
            }
        }
        return out
    }

    /// The posts in a `SearchTimeline` answer, in its order.
    static func posts(inTimeline data: Data) -> [DiscussionPost] {
        var seen = Set<String>()
        return entries(data).compactMap { entry -> DiscussionPost? in
            guard (entry["entryId"] as? String)?.hasPrefix("tweet-") == true,
                  let t = itemTweet((entry["content"] as? [String: Any])?["itemContent"] as? [String: Any]), seen.insert(t.id).inserted else { return nil }
            return DiscussionPost(place: .x, url: t.url, text: t.text, author: t.name, handle: t.handle, avatarUrl: t.avatar,
                                  published: t.published, score: t.likes, comments: t.replies, thumbnailUrl: t.photo)
        }
    }
}
