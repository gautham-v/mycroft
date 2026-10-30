import Foundation

/// A YouTube video found by Explore. Opening it stores it as an opened video (`OpenDispatchServices.openExploreVideo`),
/// so it plays in the reader's player like a pasted YouTube link.
public struct ExploreVideo: Sendable, Hashable, Identifiable {
    /// The YouTube video id.
    public var id: String
    public var title: String
    public var channel: String
    /// The channel's `UC…` id, when the result carries it.
    public var channelID: String?
    /// As YouTube words them: "1.4M views", "2 weeks ago", "18:09". Nil when the result has none (live streams).
    public var views: String?
    public var published: String?
    public var duration: String?
    public var thumbnailUrl: String

    public var watchUrl: String { "https://www.youtube.com/watch?v=\(id)" }

    /// `duration` ("5:25", "1:02:03") in seconds; nil when there is none or it doesn't read as a clock time.
    public var durationSeconds: Int? {
        guard let duration else { return nil }
        let parts = duration.split(separator: ":").map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(nil) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    public init(id: String, title: String, channel: String, channelID: String? = nil, views: String? = nil,
                published: String? = nil, duration: String? = nil, thumbnailUrl: String) {
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.views = views
        self.published = published
        self.duration = duration
        self.thumbnailUrl = thumbnailUrl
    }
}

/// A podcast episode found by Explore (iTunes Search). Opening it stores it as an opened episode
/// (`OpenDispatchServices.openExploreEpisode`), played by the reader's podcast player.
public struct ExploreEpisode: Sendable, Hashable, Identifiable {
    /// The iTunes track id.
    public var id: String
    public var title: String
    public var show: String
    /// The iTunes collection (show) id.
    public var showID: String
    public var published: Date?
    public var durationSeconds: Int?
    public var artworkUrl: String?
    public var audioUrl: String?
    /// The canonical Apple Podcasts address of the episode, which the opened item is stored under.
    public var appleUrl: String
    /// What iTunes also returns, kept so opening the episode needs no second lookup: the show notes, the show's RSS
    /// feed and the episode's Apple Podcasts page address.
    public var summary: String?
    public var feedUrl: String?
    public var pageUrl: String?

    public init(id: String, title: String, show: String, showID: String, published: Date? = nil, durationSeconds: Int? = nil,
                artworkUrl: String? = nil, audioUrl: String? = nil, appleUrl: String,
                summary: String? = nil, feedUrl: String? = nil, pageUrl: String? = nil) {
        self.id = id
        self.title = title
        self.show = show
        self.showID = showID
        self.published = published
        self.durationSeconds = durationSeconds
        self.artworkUrl = artworkUrl
        self.audioUrl = audioUrl
        self.appleUrl = appleUrl
        self.summary = summary
        self.feedUrl = feedUrl
        self.pageUrl = pageUrl
    }
}

/// What a YouTube search returns: videos, and the channels it matched (as sources to follow).
public struct ExploreVideoResults: Sendable, Hashable {
    public var videos: [ExploreVideo]
    /// Channels as `SourceSearchResult`s of kind `.youtube` (the channel's videos.xml feed, its avatar as `imageUrl`).
    public var channels: [SourceSearchResult]

    public init(videos: [ExploreVideo] = [], channels: [SourceSearchResult] = []) {
        self.videos = videos
        self.channels = channels
    }
}

/// Explore's searches. Each section is its own call so the UI can show each as it lands and one failing
/// leaves the others. Sources to follow come from `SourceSearching` plus the channels here.
public protocol ExploreSearching: Sendable {
    /// YouTube videos and channels matching the query. Throws when YouTube can't be searched.
    func videos(_ query: String) async throws -> ExploreVideoResults
    /// Podcast episodes matching the query. Throws when iTunes can't be searched.
    func episodes(_ query: String) async throws -> [ExploreEpisode]
    /// Videos uploaded in the last month, newest first, with their upload time worded in English ("3 hours ago") whatever
    /// the system language, which Topics turn into dates. Defaults to `videos`.
    func recentVideos(_ query: String) async throws -> ExploreVideoResults
    /// More episodes than `episodes` keeps (several per show), for Topics to pick the recent ones from. Defaults to `episodes`.
    func recentEpisodes(_ query: String) async throws -> [ExploreEpisode]
    /// YouTube channels matching a name or an @handle, with their counts worded in English. Defaults to `videos`' channels.
    func channels(_ query: String) async throws -> [SourceSearchResult]
}

extension ExploreSearching {
    public func recentVideos(_ query: String) async throws -> ExploreVideoResults { try await videos(query) }
    public func recentEpisodes(_ query: String) async throws -> [ExploreEpisode] { try await episodes(query) }
    public func channels(_ query: String) async throws -> [SourceSearchResult] { try await videos(query).channels }
}

