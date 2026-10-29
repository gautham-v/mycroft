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
}
