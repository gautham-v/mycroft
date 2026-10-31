import Foundation

/// A topic's block list (`TopicOptions.blocked`): where its results shouldn't come from. An entry names what the row's menu offered
/// to block: the site for an article ("note.com", which also covers its subdomains), the account for a post on X or Bluesky
/// ("@name"), the subreddit for a Reddit post ("r/name"), the channel or show for a video or an episode (its name). A Hacker News
/// story has none: it isn't from the site it links to, and Search in turns Hacker News off.
extension Topic {
    /// What blocking this item would name. Nil when it can't be blocked by itself.
    public static func blockKey(guid: String, url: String, author: String?, videoId: String?, audioUrl: String?) -> String? {
        if guid.hasPrefix("hn:") { return nil }
        if videoId != nil || audioUrl != nil {
            let name = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        let path = URLComponents(string: url)?.path.split(separator: "/").map(String.init) ?? []
        switch DiscussionPlace.thread(of: url) {
        case .x:
            guard let handle = path.first, handle != "i" else { return nil }
            return "@\(handle)"
        case .bluesky:
            guard path.count > 1, !path[1].hasPrefix("did:") else { return nil }
            return "@\(path[1])"
        case .reddit:
            guard path.count > 1, path[0] == "r" else { return nil }
            return "r/\(path[1])"
        case .hackerNews:
            return nil
        default:
            let host = URLHost.host(of: url)
            return host.isEmpty ? nil : host
        }
    }

    /// `key` is on the list, or is a subdomain of a site on it. Ignores case.
    public static func isBlocked(_ key: String, by blocked: [String]) -> Bool {
        let k = key.lowercased()
        return blocked.contains { entry in
            let b = entry.lowercased()
            return k == b || k.hasSuffix("." + b)
        }
    }
}

extension TopicOptions {
    /// A result from somewhere on the block list.
    public func isBlocked(guid: String, url: String, author: String?, videoId: String?, audioUrl: String?) -> Bool {
        guard !blocked.isEmpty,
              let key = Topic.blockKey(guid: guid, url: url, author: author, videoId: videoId, audioUrl: audioUrl) else { return false }
        return Topic.isBlocked(key, by: blocked)
    }
}

extension FeedItem {
    /// What Block would name for this row (`Topic.blockKey`).
    public var topicBlockKey: String? {
        Topic.blockKey(guid: item.guid, url: item.url, author: item.author, videoId: item.videoId, audioUrl: item.audioUrl)
    }
}
