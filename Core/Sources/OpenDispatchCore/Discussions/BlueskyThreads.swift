import Foundation

/// Bluesky's AppView, which needs no account: `searchPosts` (only api.bsky.app answers it; public.api.bsky.app refuses
/// search) for the most-liked posts of the last two weeks, and `getPostThread` for a post's replies, most liked first.
enum BlueskyThreads {
    static let searchWindow: TimeInterval = 14 * 24 * 3600
    static let threadDepth = 6

    static func searchURL(_ query: String, now: Date) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;:")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = q.contains(" ") && !q.contains("\"") ? "\"\(q)\"" : q
        let since = ISO8601.string(from: now.addingTimeInterval(-searchWindow))
        return "https://api.bsky.app/xrpc/app.bsky.feed.searchPosts?q=\(phrase.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)&sort=top&limit=25&since=\(since.addingPercentEncoding(withAllowedCharacters: allowed) ?? since)"
    }

    static func posts(inSearch data: Data) throws -> [DiscussionPost] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let posts = root["posts"] as? [[String: Any]] else {
            throw DiscussionError.unavailable
        }
        return posts.compactMap(post)
    }

    private static func post(_ p: [String: Any]) -> DiscussionPost? {
        guard let uri = p["uri"] as? String, let rkey = uri.split(separator: "/").last,
              let author = p["author"] as? [String: Any], let handle = author["handle"] as? String,
              let record = p["record"] as? [String: Any] else { return nil }
        let name = (author["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let embed = p["embed"] as? [String: Any]
        let media = (embed?["media"] as? [String: Any]) ?? embed
        let thumb = ((media?["images"] as? [[String: Any]])?.first?["thumb"] as? String) ?? (media?["thumbnail"] as? String)
            ?? ((media?["external"] as? [String: Any])?["thumb"] as? String)
        return DiscussionPost(
            place: .bluesky, url: "https://bsky.app/profile/\(handle)/post/\(rkey)", text: record["text"] as? String,
            author: name?.isEmpty == false ? name : handle, handle: handle, avatarUrl: author["avatar"] as? String,
            published: DiscussionDates.parse(record["createdAt"] as? String), score: p["likeCount"] as? Int,
            comments: p["replyCount"] as? Int, thumbnailUrl: thumb)
    }

    /// The thread request for a post's address; nil for anything that isn't a Bluesky post.
    static func threadURL(_ url: String) -> String? {
        guard let m = SocialPosts.blueskyURL.firstMatch(url), let actor = m[1], let rkey = m[2] else { return nil }
        let uri = ExtractionDOM.encodeURIComponent("at://\(actor)/app.bsky.feed.post/\(rkey)")
        return "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=\(uri)&depth=\(threadDepth)&parentHeight=0"
    }

    /// The replies under the thread's post, depth first, the most liked first at each level. Blocked and deleted replies
    /// are left out.
    static func thread(_ data: Data) throws -> DiscussionThread {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = root["thread"] as? [String: Any], let post = thread["post"] as? [String: Any] else {
            throw DiscussionError.notFound
        }
        let op = (post["author"] as? [String: Any])?["did"] as? String
        var out: [DiscussionEntry] = []
        func visit(_ replies: [[String: Any]], depth: Int) {
            let sorted = replies.sorted { likes($0) > likes($1) }
            for r in sorted {
                guard r["$type"] as? String == "app.bsky.feed.defs#threadViewPost", let p = r["post"] as? [String: Any],
                      let uri = p["uri"] as? String, let record = p["record"] as? [String: Any],
                      let author = p["author"] as? [String: Any], let handle = author["handle"] as? String else { continue }
                let name = (author["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rkey = uri.split(separator: "/").last.map(String.init) ?? uri
                let html = BlueskyPost.paragraphs(record).map { "<p>\($0)</p>" }.joined()
                out.append(.comment(DiscussionComment(
                    id: uri, author: name.isEmpty ? "@\(handle)" : "\(name) @\(handle)", avatarUrl: author["avatar"] as? String,
                    body: RichText.html(html), published: DiscussionDates.parse(record["createdAt"] as? String),
                    score: p["likeCount"] as? Int, depth: depth, url: "https://bsky.app/profile/\(handle)/post/\(rkey)",
                    byAuthor: op != nil && author["did"] as? String == op)))
                visit(r["replies"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        visit(thread["replies"] as? [[String: Any]] ?? [], depth: 0)
        return DiscussionThread(entries: out, total: post["replyCount"] as? Int)
    }

    private static func likes(_ reply: [String: Any]) -> Int {
        ((reply["post"] as? [String: Any])?["likeCount"] as? Int) ?? 0
    }
}
