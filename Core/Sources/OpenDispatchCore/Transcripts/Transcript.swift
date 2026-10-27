import Foundation

/// A video's or podcast episode's spoken text, for Copy as Markdown. Owner: Transcripts.
public struct Transcript: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        /// YouTube's captions for the video (manual first, then auto-generated).
        case youtubeCaptions
        /// The episode's `<podcast:transcript>` file from the feed.
        case podcastFeed

        /// Shown after the "Transcript" heading: "## Transcript (YouTube captions)".
        public var label: String {
            switch self {
            case .youtubeCaptions: "YouTube captions"
            case .podcastFeed: "from the podcast feed"
            }
        }
    }

    public struct Segment: Sendable, Hashable {
        /// Seconds from the start; nil when the format has no timing (plain text, HTML).
        public var start: TimeInterval?
        public var speaker: String?
        public var text: String

        public init(start: TimeInterval?, speaker: String? = nil, text: String) {
            self.start = start
            self.speaker = speaker
            self.text = text
        }
    }

    public var origin: Origin
    public var segments: [Segment]

    public init(origin: Origin, segments: [Segment]) {
        self.origin = origin
        self.segments = segments
    }
}

/// Finds a transcript for an item: YouTube captions for youtube sources, the feed's `<podcast:transcript>`
/// for podcast sources, nil for everything else. Returns nil (does not throw) when there is none;
/// throws only for network failures worth telling the user about.
public protocol TranscriptFetching: Sendable {
    func transcript(for item: Item, source: Source) async throws -> Transcript?
}
