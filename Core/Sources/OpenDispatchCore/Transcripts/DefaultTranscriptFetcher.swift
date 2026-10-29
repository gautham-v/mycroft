import Foundation

/// YouTube captions for youtube sources (see `YouTubeCaptions`); for podcast episodes, Substack's transcript
/// (`SubstackTranscript`) or the feed's `<podcast:transcript>`.
/// Items aren't stored with a transcript URL, so the source's feed is fetched again at copy time and the episode found by guid.
public struct DefaultTranscriptFetcher: TranscriptFetching {
    let parser: any FeedParser
    let session: URLSession
    /// Preferred transcript language (primary subtag); nil = the system's.
    let language: String?

    static let feedTimeout: TimeInterval = 15
    static let fileTimeout: TimeInterval = 20
    /// How many of a feed's tracks to try before giving up (the best ones first).
    static let maxTracks = 3

    public init(parser: any FeedParser) {
        self.init(parser: parser, session: HTTP.session)
    }

    init(parser: any FeedParser, session: URLSession, language: String? = Locale.current.language.languageCode?.identifier) {
        self.parser = parser
        self.session = session
        self.language = language
    }

    public func transcript(for item: Item, source: Source) async throws -> Transcript? {
        switch source.kind {
        case .youtube:
            guard let videoID = item.videoId, !videoID.isEmpty else { return nil }
            return try await YouTubeCaptions.transcript(videoID: videoID, language: language, session: session)
        case .podcast, .rss where item.audioUrl != nil:
            var item = item
            var feed: (url: String, data: Data)?
            if source.holdsStandaloneItems {
                // An opened episode (or a topic's) lives under a holder source: its show's feed gives the entry's own guid and link.
                guard let found = await openedEpisodeEntry(item) else { return nil }
                feed = (found.feedURL, found.data)
                item.guid = found.entry.guid
                item.url = found.entry.url
            }
            // Substack feeds never carry <podcast:transcript>; its own transcript is in the post's JSON.
            if SubstackTranscript.isSubstack(item), let t = try? await SubstackTranscript.transcript(for: item, session: session) {
                return t
            }
            return try await podcastTranscript(for: item, source: source, feed: feed)
        case .rss, .page, .topic:
            return nil
        }
    }

    /// The feed's entry for an opened Apple Podcasts episode, with the feed it was read from; nil for an audio
    /// file (no show) or an episode the feed doesn't list.
    func openedEpisodeEntry(_ item: Item) async -> (feedURL: String, data: Data, entry: ParsedItem)? {
        let fetch = ApplePodcastEpisode.liveFetch(session: session)
        guard let feedURL = await OpenedLinks.episodeFeedURL(for: item, fetch: fetch),
              let data = try? await fetch(feedURL),
              let entry = ApplePodcastEpisode.entry(in: data, feedURL: feedURL, for: item, parser: parser)
        else { return nil }
        return (feedURL, data, entry)
    }

    /// `feed` is the already-fetched feed of an opened episode, whose own feed URL is not the source's.
    func podcastTranscript(for item: Item, source: Source, feed known: (url: String, data: Data)? = nil) async throws -> Transcript? {
        let feedURL = known?.url ?? source.feedUrl
        let feed: Data
        if let known {
            feed = known.data
        } else {
            let (data, res) = try await HTTP.fetch(feedURL, timeout: Self.feedTimeout, headers: ["Accept": HTTP.feedAccept], session: session)
            guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
            feed = data
        }
        let tracks = parser.itemTranscripts(in: feed, guid: item.guid, url: item.url)
        var lastError: (any Error)?
        for (track, format) in TranscriptParsing.ranked(tracks, language: language).prefix(Self.maxTracks) {
            guard let url = FeedParsingSupport.absolutize(track.url, base: feedURL) else { continue }
            do {
                let (data, res) = try await HTTP.fetchOK(url, timeout: Self.fileTimeout, headers: ["Accept": "*/*"], session: session)
                let segments = TranscriptParsing.segments(HTTP.text(data, response: res), format: format)
                if !segments.isEmpty { return Transcript(origin: .podcastFeed, segments: segments) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }
}
