import Foundation

/// Hacker News through Algolia's API, which needs no key: the search (stories of the last month by relevance) and an item's
/// whole comment tree (`/api/v1/items/<id>`) in one answer. Comments are HTML and carry no points.
enum HackerNewsThreads {
    private static let itemURL = ExtractionDOM.Pattern(#"^https?://news\.ycombinator\.com/item\?(?:.*&)?id=(\d+)"#, caseInsensitive: true)

    /// The item id in a news.ycombinator.com/item?id= address.
    static func itemID(_ url: String) -> String? {
        itemURL.firstMatch(url)?[1] ?? nil
    }

    static func url(id: String) -> String { "https://news.ycombinator.com/item?id=\(id)" }

    static let searchWindow: TimeInterval = 30 * 24 * 3600

    static func searchURL(_ query: String, now: Date) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = q.contains(" ") && !q.contains("\"") ? "\"\(q)\"" : q
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;\"<>")
        let since = Int(now.timeIntervalSince1970 - searchWindow)
        let filter = "created_at_i>\(since)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "https://hn.algolia.com/api/v1/search?query=\(phrase.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)&tags=story&hitsPerPage=20&numericFilters=\(filter)"
    }

    static func posts(inSearch data: Data) throws -> [DiscussionPost] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = root["hits"] as? [[String: Any]] else {
            throw DiscussionError.unavailable
        }
        return hits.compactMap { h in
            guard let id = h["objectID"] as? String, let title = h["title"] as? String, !title.isEmpty else { return nil }
            let link = (h["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DiscussionPost(
                place: .hackerNews, url: url(id: id), title: title, author: h["author"] as? String, handle: h["author"] as? String,
                published: (h["created_at_i"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                score: h["points"] as? Int, comments: h["num_comments"] as? Int, link: link)
        }
    }

    static func itemAPI(id: String) -> String { "https://hn.algolia.com/api/v1/items/\(id)" }

    /// An item from `/api/v1/items/<id>`.
    struct Item {
        var id: String
        var title: String?
        var author: String?
        var link: String?
        /// An Ask HN's or a comment's text, HTML.
        var text: String?
        var points: Int?
        var published: Date?
        var children: [[String: Any]]
    }

    static func item(_ data: Data) throws -> Item {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = root["id"] as? Int else {
            throw DiscussionError.notFound
        }
        return Item(id: String(id), title: root["title"] as? String, author: root["author"] as? String,
                    link: (root["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }, text: root["text"] as? String,
                    points: root["points"] as? Int, published: (root["created_at_i"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    children: root["children"] as? [[String: Any]] ?? [])
    }

    /// Every comment, depth first in the site's order. Deleted comments with no replies are left out; one with replies
    /// stays as "[deleted]" so the replies have a parent.
    static func thread(_ data: Data) throws -> DiscussionThread {
        let root = try item(data)
        var out: [DiscussionEntry] = []
        func visit(_ nodes: [[String: Any]], depth: Int) {
            for n in nodes {
                let children = n["children"] as? [[String: Any]] ?? []
                guard let id = n["id"] as? Int else { continue }
                let text = n["text"] as? String
                let author = n["author"] as? String
                if text == nil || author == nil {
                    if children.isEmpty { continue }
                    out.append(.comment(DiscussionComment(id: String(id), author: "[deleted]", body: RichText.plain("[deleted]"), depth: depth)))
                } else if let text, let author {
                    out.append(.comment(DiscussionComment(
                        id: String(id), author: author, body: RichText.html(text, base: "https://news.ycombinator.com/"),
                        published: (n["created_at_i"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        depth: depth, url: url(id: String(id)), byAuthor: author == root.author)))
                }
                visit(children, depth: depth + 1)
            }
        }
        visit(root.children, depth: 0)
        return DiscussionThread(entries: out, total: out.count)
    }

    /// An item as reader markup: an Ask HN's text, and a link to the story's article.
    static func contentHTML(_ item: Item) -> String? {
        var parts: [String] = []
        if let link = item.link {
            let host = ExtractionDOM.hostname(link) ?? link
            parts.append("<p><a href=\"\(ExtractionDOM.escapeAttr(link))\">\(ExtractionDOM.escapeHTML(host))</a></p>")
        }
        if let text = item.text, !text.isEmpty { parts.append(text.hasPrefix("<p>") ? text : "<p>\(text)</p>") }
        let html = ArticleSanitizer.sanitize(parts.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : html
    }
}
