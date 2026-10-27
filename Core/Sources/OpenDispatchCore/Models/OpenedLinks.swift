import Foundation
import GRDB

/// Links typed into a new tab's address field. Each is stored as an item of one of three built-in
/// sources that aren't subscriptions: YouTube videos go to a `.youtube` one so they play like channel
/// videos, Apple Podcasts episodes and audio files to a `.podcast` one so they get the audio player,
/// everything else to a `.page` one. Those sources are never refreshed, listed, exported or synced as
/// sources (`Queries.sources` leaves them out), their items show only in Saved, and an unsaved one is
/// pruned 14 days after it was opened. Saving, highlights and Copy as Markdown work as for any item; a
/// saved link or a highlight arriving from iCloud recreates its source here.
public enum OpenedLinks {
    public static let linksFeedURL = "opendispatch:opened-links"
    public static let videosFeedURL = "opendispatch:opened-videos"
    public static let episodesFeedURL = "opendispatch:opened-episodes"
    static let feedURLs = [linksFeedURL, videosFeedURL, episodesFeedURL]

    public static func isOpenedLinks(feedUrl: String) -> Bool { feedURLs.contains(feedUrl) }

    /// The source a reserved feed URL stands for, not yet inserted; nil for any other URL.
    static func template(feedUrl: String, now: Date) -> Source? {
        switch feedUrl {
        case linksFeedURL:
            Source(title: "Opened links", url: "https://opendispatch.app", feedUrl: feedUrl, kind: .page,
                   group: SourceGroup.blogs, createdAt: now)
        case videosFeedURL:
            Source(title: "Opened videos", url: "https://www.youtube.com", feedUrl: feedUrl, kind: .youtube,
                   group: SourceGroup.youtube, createdAt: now)
        case episodesFeedURL:
            Source(title: "Opened episodes", url: "https://opendispatch.app", feedUrl: feedUrl, kind: .podcast,
                   group: SourceGroup.podcast, createdAt: now)
        default:
            nil
        }
    }

    /// The holder an item opened from a link is stored under.
    static func feedURL(for item: ParsedItem) -> String {
        if item.videoId != nil { return videosFeedURL }
        return item.audioUrl != nil ? episodesFeedURL : linksFeedURL
    }

    /// The video id in a YouTube watch, Shorts, live, embed or youtu.be link; nil for anything else.
    public static func youTubeVideoID(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let raw = c.host?.lowercased() else { return nil }
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw.hasPrefix("m.") ? String(raw.dropFirst(2)) : raw
        let segs = c.path.split(separator: "/").map(String.init)
        let id: String?
        switch host {
        case "youtu.be":
            id = segs.first
        case "youtube.com", "music.youtube.com", "youtube-nocookie.com":
            if segs.first == "watch" {
                id = c.queryItems?.first { $0.name == "v" }?.value
            } else if segs.count >= 2, ["shorts", "live", "embed", "v"].contains(segs[0]) {
                id = segs[1]
            } else {
                id = nil
            }
        default:
            id = nil
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return id
    }

    /// The link as stored: a video's canonical watch URL, otherwise the address without its #fragment.
    public static func canonicalURL(_ url: String, videoID: String?) -> String {
        if let videoID { return "https://www.youtube.com/watch?v=\(videoID)" }
        guard var c = URLComponents(string: url) else { return url }
        c.fragment = nil
        return c.string ?? url
    }

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac"]

    /// The address ends in an audio file extension (the query is ignored).
    public static func isAudioURL(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), c.host != nil, !c.path.hasSuffix("/") else { return false }
        return audioExtensions.contains((c.path as NSString).pathExtension.lowercased())
    }

    /// A response Content-Type of `audio/*`.
    public static func isAudioContentType(_ contentType: String?) -> Bool {
        contentType?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("audio/") == true
    }

    /// The item for a link to an audio file: the file name as the title, played by the reader's player.
    /// There is no page to read, so no description, date or art; the file's host stands in as the source.
    public static func audioItem(url: String, now: Date = Date()) -> ParsedItem {
        let path = URLComponents(string: url)?.path ?? ""
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.removingPercentEncoding ?? ""
        let words = name.replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedItem(guid: url, url: url, title: words.isEmpty ? URLHost.host(of: url) : words, publishedAt: now, audioUrl: url)
    }

    /// A page title as the item's: without the invisible direction marks Apple Podcasts puts around it and
    /// the site-name tail Apple Podcasts and Spotify add. nil for what is no title at all, such as the
    /// "Spotify - Web Player" shell a player page serves without a login.
    public static func cleanedTitle(_ title: String, url: String) -> String? {
        var t = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}")))
        let host = URLHost.host(of: url)
        if host.hasSuffix("apple.com") {
            t = t.replacingOccurrences(of: "(\\s+on|\\s*[-\u{2013}|])\\s+Apple Podcasts$", with: "", options: .regularExpression)
        } else if host.hasSuffix("spotify.com") {
            if t.range(of: "^Spotify(\\s+[-\u{2013}]\\s+Web Player)?$", options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            t = t.replacingOccurrences(
                of: "\\s*[-\u{2013}|]\\s*(Listen to the Podcast on Spotify|Podcast on Spotify|Spotify)$",
                with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The item for a link whose page couldn't be read: its address as the title, opened now.
    public static func fallbackItem(url: String, videoID: String?, now: Date = Date()) -> ParsedItem {
        let host = URLHost.host(of: url)
        let path = URLComponents(string: url)?.path ?? ""
        return ParsedItem(
            guid: url, url: url, title: videoID == nil ? host + (path == "/" ? "" : path) : "YouTube video",
            publishedAt: now, thumbnailUrl: videoID.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" }, videoId: videoID)
    }
}

extension Source {
    /// One of the OpenedLinks holders rather than a subscription.
    public var isOpenedLinks: Bool { OpenedLinks.isOpenedLinks(feedUrl: feedUrl) }

    /// The source an item names in lists and the reader: this one, or for an opened link the item's own
    /// site (a video's channel, an episode's show), so it reads like an article from any other source.
    public func shown(for item: Item) -> Source {
        guard isOpenedLinks else { return self }
        var s = self
        if kind == .youtube {
            s.title = item.author.flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube"
        } else if kind == .podcast {
            let host = URLHost.host(of: item.url)
            s.title = item.author.flatMap { $0.isEmpty ? nil : $0 } ?? (host.isEmpty ? title : host)
            if let c = URLComponents(string: item.url), let scheme = c.scheme, let h = c.host { s.url = "\(scheme)://\(h)" }
        } else {
            let host = URLHost.host(of: item.url)
            s.title = host.isEmpty ? title : host
            if let c = URLComponents(string: item.url), let scheme = c.scheme, let h = c.host { s.url = "\(scheme)://\(h)" }
        }
        return s
    }
}

extension OpenedLinks {
    /// The RSS feed of the show an opened episode belongs to, which its show notes and transcript are read
    /// from; nil for an audio file, which has no show. Nothing is stored for it: an Apple Podcasts episode
    /// names its show in its address, and the lookup API gives the feed.
    static func episodeFeedURL(for item: Item, fetch: ApplePodcastEpisode.Fetch) async -> String? {
        guard let link = ApplePodcastEpisode.link(item.guid) else { return nil }
        return await ApplePodcastEpisode.feedURL(showID: link.showID, country: link.country, fetch: fetch)
    }
}

extension Queries {
    /// The source with this feed URL, inserting it first when it's an OpenedLinks holder not yet here.
    static func sourceCreatingOpenedLinks(_ db: Database, feedUrl: String, now: Date = Date()) throws -> Source? {
        if let s = try source(db, feedUrl: feedUrl) { return s }
        guard var s = OpenedLinks.template(feedUrl: feedUrl, now: now) else { return nil }
        try s.insert(db)
        return s
    }

    /// An opened link already stored, by its canonical URL.
    public static func openedLink(_ db: Database, feedUrl: String, url: String) throws -> FeedItem? {
        guard let s = try source(db, feedUrl: feedUrl),
              let id = try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE source_id = ? AND guid = ?", arguments: [s.id, url])
        else { return nil }
        return try feedItem(db, id: id)
    }

    /// Store an opened link (its holder source is created on first use) and return its row.
    public static func insertOpenedLink(_ db: Database, _ item: ParsedItem, now: Date = Date()) throws -> FeedItem {
        guard let s = try sourceCreatingOpenedLinks(db, feedUrl: OpenedLinks.feedURL(for: item), now: now),
              let row = try upsertItems(db, sourceId: s.id, items: [item], now: now).first,
              let out = try feedItem(db, id: row.id)
        else { throw QueryError.notFound("Item") }
        return out
    }
}
