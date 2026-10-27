import Foundation

/// A video's or podcast episode's spoken text, for Copy as Markdown. Owner: Transcripts.
public struct Transcript: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        /// YouTube's captions for the video (manual first, then auto-generated).
        case youtubeCaptions
        /// The episode's `<podcast:transcript>` file from the feed.
        case podcastFeed
        /// Substack's transcript of a podcast or video post (`SubstackTranscript`).
        case substack

        /// Shown after the "Transcript" heading: "## Transcript (YouTube captions)".
        public var label: String {
            switch self {
            case .youtubeCaptions: "YouTube captions"
            case .podcastFeed: "from the podcast feed"
            case .substack: "from Substack"
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

extension Transcript {
    /// Cues read as one run of text: a line of Copy as Markdown's transcript, a paragraph in the reader.
    public struct Paragraph: Sendable, Hashable {
        public var start: TimeInterval?
        public var speaker: String?
        public var text: String
    }

    /// Caption cues grouped into paragraphs of roughly 20 to 40 seconds, a new one when the speaker
    /// changes. Untimed segments stay one paragraph each.
    public var paragraphs: [Paragraph] {
        var lines: [Paragraph] = []
        for seg in segments {
            let text = MarkdownConverter.collapse(seg.text).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let speaker = seg.speaker.map(ItemMarkdown.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            if var cur = lines.last, let curStart = cur.start, let start = seg.start, cur.speaker == speaker {
                let elapsed = start - curStart
                let sentenceEnd = cur.text.last.map { ".?!\"”".contains($0) } ?? false
                if elapsed < 40 && !(elapsed >= 20 && sentenceEnd) {
                    cur.text += " " + text
                    lines[lines.count - 1] = cur
                    continue
                }
            }
            lines.append(Paragraph(start: seg.start, speaker: speaker, text: text))
        }
        return lines
    }

    /// The paragraphs as timestamped Markdown, as Copy as Markdown writes them under "## Transcript".
    public func markdown(durationSec: Int?) -> String {
        ItemMarkdown.transcriptText(self, long: ItemMarkdown.isLong(self, durationSec: durationSec))
    }

    public var wordCount: Int { ItemMarkdown.wordCount(self) }
}

/// Finds a transcript for an item: YouTube captions for youtube sources, the feed's `<podcast:transcript>`
/// for podcast sources, nil for everything else. Returns nil (does not throw) when there is none;
/// throws only for network failures worth telling the user about.
public protocol TranscriptFetching: Sendable {
    func transcript(for item: Item, source: Source) async throws -> Transcript?
}
