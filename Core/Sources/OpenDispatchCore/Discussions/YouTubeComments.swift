import Foundation

/// A video's comments through YouTube's own innertube `next` endpoint, no key, as the watch page loads them: the watch
/// answer's comment section holds a continuation token, which answers with the first page of comment threads (Top
/// comments). Each thread carries a token for its replies and the page a token for the next page; both become
/// `DiscussionMore`s whose token is the continuation. A comment's text, author and counts aren't in the thread itself but in
/// `frameworkUpdates.entityBatchUpdate.mutations`, keyed by the thread's `commentKey`.
enum YouTubeComments {
    static let nextURL = "https://www.youtube.com/youtubei/v1/next?prettyPrint=false"

    static func body(videoID: String? = nil, continuation: String? = nil) -> Data {
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": DefaultExploreSearch.clientVersion, "hl": "en", "gl": "US"]],
        ]
        if let videoID { body["videoId"] = videoID }
        if let continuation { body["continuation"] = continuation }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The token that loads the first page of comments, from the watch answer; nil when comments are off.
    static func commentsToken(inWatch data: Data) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: data)
        var section: Any?
        walk(json) { dict in
            if section == nil, let s = dict["itemSectionRenderer"] as? [String: Any], s["sectionIdentifier"] as? String == "comment-item-section" {
                section = s
            }
        }
        return section.flatMap(firstToken)
    }

    /// The comments in a continuation answer at `depth` (0 for threads, 1 for replies), each thread followed by a
    /// `DiscussionMore` for its replies, and one at the end for the next page.
    static func entries(_ data: Data, depth: Int, now: Date = Date()) throws -> [DiscussionEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscussionError.unavailable }
        var payloads: [String: [String: Any]] = [:]
        let mutations = ((root["frameworkUpdates"] as? [String: Any])?["entityBatchUpdate"] as? [String: Any])?["mutations"] as? [[String: Any]] ?? []
        for m in mutations {
            if let p = (m["payload"] as? [String: Any])?["commentEntityPayload"] as? [String: Any], let key = (m["entityKey"] as? String) ?? (p["key"] as? String) {
                payloads[key] = p
            }
        }
        var out: [DiscussionEntry] = []
        for endpoint in root["onResponseReceivedEndpoints"] as? [[String: Any]] ?? [] {
            for (key, value) in endpoint where key != "clickTrackingParams" {
                for item in (value as? [String: Any])?["continuationItems"] as? [[String: Any]] ?? [] {
                    if let thread = item["commentThreadRenderer"] as? [String: Any] {
                        let model = (thread["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any]
                        guard let c = model.flatMap({ comment($0, payloads, depth: depth, now: now) }) else { continue }
                        out.append(.comment(c))
                        if let replies = thread["replies"], let token = firstToken(replies) {
                            out.append(.more(DiscussionMore(token: token, depth: depth + 1, count: replyCount(c.id, payloads))))
                        }
                    } else if let model = item["commentViewModel"] as? [String: Any] {
                        if let c = comment(model, payloads, depth: depth, now: now) { out.append(.comment(c)) }
                    } else if let more = item["continuationItemRenderer"], let token = firstToken(more) {
                        out.append(.more(DiscussionMore(token: token, depth: depth)))
                    }
                }
            }
        }
        return out
    }

    private static func comment(_ model: [String: Any], _ payloads: [String: [String: Any]], depth: Int, now: Date) -> DiscussionComment? {
        guard let key = model["commentKey"] as? String, let p = payloads[key],
              let props = p["properties"] as? [String: Any] else { return nil }
        let author = p["author"] as? [String: Any]
        let toolbar = p["toolbar"] as? [String: Any]
        let text = ((props["content"] as? [String: Any])?["content"] as? String) ?? ""
        let id = (props["commentId"] as? String) ?? key
        return DiscussionComment(
            id: id, author: (author?["displayName"] as? String) ?? "", avatarUrl: author?["avatarThumbnailUrl"] as? String,
            body: RichText.plain(text),
            published: (props["publishedTime"] as? String).flatMap { DefaultTopicSearch.publishedDate(relative: $0, now: now) },
            score: (toolbar?["likeCountNotliked"] as? String).flatMap(compactNumber), depth: depth,
            byAuthor: author?["isCreator"] as? Bool == true)
    }

    private static func replyCount(_ id: String, _ payloads: [String: [String: Any]]) -> Int? {
        for p in payloads.values where (p["properties"] as? [String: Any])?["commentId"] as? String == id {
            return ((p["toolbar"] as? [String: Any])?["replyCount"] as? String).flatMap(compactNumber)
        }
        return nil
    }

    /// "70K", "1.2M", "650", "1,234" as a number; nil for "" or words.
    static func compactNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let last = t.last else { return nil }
        let scale: Double = switch last.uppercased() {
        case "K": 1_000
        case "M": 1_000_000
        case "B": 1_000_000_000
        default: 1
        }
        guard let n = Double(scale == 1 ? t : String(t.dropLast())) else { return nil }
        return Int((n * scale).rounded())
    }

    /// The first `continuationCommand.token` at or below `node`.
    private static func firstToken(_ node: Any) -> String? {
        var token: String?
        walk(node) { dict in
            if token == nil, let c = dict["continuationCommand"] as? [String: Any] { token = c["token"] as? String }
        }
        return token
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit) }
        } else if let array = node as? [Any] {
            for element in array { walk(element, visit) }
        }
    }
}
