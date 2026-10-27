import Foundation
import Testing
@testable import OpenDispatchCore

private let parser = DefaultFeedParser()

private enum TFixture {
    static let vtt = """
    WEBVTT
    Kind: captions

    STYLE
    ::cue { color: red }

    NOTE This is a comment
    spanning two lines

    intro
    00:00:01.000 --> 00:00:03.500 align:start
    <v Ben>I&apos;m sorry, I got <c.loud>tripped</c> up.</v>

    00:01:05.250 --> 00:01:07.000
    <v.first.loud David Rosenthal>Fish &amp; chips,
    second line.</v>

    01:02.000 --> 01:03.000
    No voice here.

    00:02:00.000 --> 00:02:01.000
    <c></c>
    """

    static let srt = "\u{FEFF}1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>Hello</i> there.\r\n\r\n2\r\n00:00:03,000 --> 00:00:05,000\r\nSecond {\\an8}line\r\ncontinues.\r\n\r\n3\r\n00:00:05,000 --> 00:00:06,000\r\n\r\n"

    static let json = """
    {"version":"1.0.0","segments":[
      {"startTime":0,"endTime":4.5,"speaker":"Alice","body":"Welcome to the show."},
      {"startTime":4.5,"endTime":9,"body":"  Today: caf\\u00e9 culture.  "},
      {"startTime":9,"endTime":10,"speaker":"Bob","body":"   "}
    ]}
    """

    static func feed(items: String) -> String {
        """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
        <channel><title>Show</title><link>https://show.example.com</link>\(items)</channel></rss>
        """
    }

    static let episodes = feed(items: """
        <item><title>One</title><guid isPermaLink="false">ep-1</guid><link>https://show.example.com/1</link>
          <enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg"/>
          <podcast:transcript url="https://show.example.com/1.txt" type="text/plain"/>
          <podcast:transcript url="/1.vtt" type="text/vtt; charset=utf-8" language="en" rel="captions"/>
        </item>
        <item><title>Two</title><guid>ep-2</guid><link>https://show.example.com/2</link>
          <enclosure url="https://cdn.example.com/2.mp3" type="audio/mpeg"/>
        </item>
        """)

    static let playerResponse = """
    {"playabilityStatus":{"status":"OK"},"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
      {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=de&fmt=srv3","languageCode":"de","name":{"runs":[{"text":"German"}]}},
      {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=en&kind=asr","languageCode":"en","kind":"asr"},
      {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=en","languageCode":"en"},
      {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=fr&exp=xpe","languageCode":"fr"}
    ]}}}
    """

    static let timedText = """
    <?xml version="1.0" encoding="utf-8" ?><transcript>
    <text start="0.32" dur="1.9">Last week, an anonymous mystery model</text>
    <text start="2.24" dur="1.92">that&amp;#39;s &amp;quot;wild&amp;quot; &amp;amp; fast</text>
    <text start="4.16" dur="2">tags &lt;font color="#fff"&gt;stripped&lt;/font&gt; &amp;gt; here</text>
    <text start="6.1" dur="1"> </text>
    <text start="7">no duration</text>
    </transcript>
    """
}

@Suite("Transcripts: formats")
struct TranscriptFormatTests {
    @Test func vttWithVoiceTags() {
        let s = TranscriptParsing.segments(TFixture.vtt, format: .vtt)
        #expect(s == [
            .init(start: 1.0, speaker: "Ben", text: "I'm sorry, I got tripped up."),
            .init(start: 65.25, speaker: "David Rosenthal", text: "Fish & chips, second line."),
            .init(start: 62.0, speaker: nil, text: "No voice here."),
        ])
    }

    @Test func srt() {
        let s = TranscriptParsing.segments(TFixture.srt, format: .srt)
        #expect(s == [
            .init(start: 1.5, text: "Hello there."),
            .init(start: 3.0, text: "Second line continues."),
        ])
    }

    @Test func podcastIndexJSON() {
        let s = TranscriptParsing.segments(TFixture.json, format: .json)
        #expect(s == [
            .init(start: 0, speaker: "Alice", text: "Welcome to the show."),
            .init(start: 4.5, text: "Today: café culture."),
        ])
    }

    @Test func htmlParagraphs() {
        let html = """
        <html><head><title>x</title><style>p{}</style></head><body>
        <h1>Episode &amp; notes</h1>
        <p>[00:00:05] Hello <b>there</b>, it&#8217;s us.</p>
        <p>12:30 - Later on</p>
        <p>Just text, no time.</p>
        <p>   </p>
        <p>12:30pm is lunch.</p>
        </body></html>
        """
        let s = TranscriptParsing.segments(html, format: .html)
        #expect(s == [
            .init(start: nil, text: "Episode & notes"),
            .init(start: 5, text: "Hello there, it\u{2019}s us."),
            .init(start: 750, text: "Later on"),
            .init(start: nil, text: "Just text, no time."),
            .init(start: nil, text: "12:30pm is lunch."),
        ])
    }

    @Test func plainTextParagraphs() {
        #expect(TranscriptParsing.segments("One\ntwo.\n\n\nThree.\n", format: .text) == [
            .init(start: nil, text: "One two."), .init(start: nil, text: "Three."),
        ])
        #expect(TranscriptParsing.segments("Line one\nLine two\n", format: .text).count == 2)
        #expect(TranscriptParsing.segments("  \n ", format: .text).isEmpty)
    }

    @Test func declaredTypeIsOverriddenByTheBody() {
        // Darknet Diaries labels its .vtt files text/plain.
        let s = TranscriptParsing.segments("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n", format: .text)
        #expect(s == [.init(start: 1, text: "Hi")])
    }

    @Test func formatDetection() {
        #expect(TranscriptFormat.detect(type: "Application/JSON; charset=utf-8", url: "https://e.com/x") == .json)
        #expect(TranscriptFormat.detect(type: "application/x-subrip", url: "https://e.com/x") == .srt)
        #expect(TranscriptFormat.detect(type: nil, url: "https://e.com/t.vtt?sig=1") == .vtt)
        #expect(TranscriptFormat.detect(type: "application/pdf", url: "https://e.com/t.pdf") == nil)
    }
}

@Suite("Transcripts: podcast feed")
struct PodcastTranscriptFeedTests {
    @Test func parsesEveryTranscriptTag() {
        let tracks = parser.itemTranscripts(in: Data(TFixture.episodes.utf8), guid: "ep-1", url: "https://show.example.com/1")
        #expect(tracks == [
            .init(url: "https://show.example.com/1.txt", type: "text/plain"),
            .init(url: "/1.vtt", type: "text/vtt; charset=utf-8", language: "en", rel: "captions"),
        ])
    }

    @Test func guidLookup() {
        let data = Data(TFixture.episodes.utf8)
        #expect(parser.itemTranscripts(in: data, guid: "ep-2", url: "https://show.example.com/2").isEmpty)
        #expect(parser.itemTranscripts(in: data, guid: "nope", url: "https://elsewhere.example.com/").isEmpty)
        // No guid match: falls back to the link, like itemHTML.
        #expect(parser.itemTranscripts(in: data, guid: "nope", url: "https://show.example.com/1/").count == 2)
        #expect(parser.itemTranscripts(in: Data("not xml".utf8), guid: "ep-1", url: "x").isEmpty)
    }

    @Test func typePreferenceOrder() {
        let all = ["text/plain", "text/html", "application/srt", "text/vtt", "application/json"]
            .map { FeedTranscriptTrack(url: "https://e.com/\($0.hashValue)", type: $0) }
        let order = TranscriptParsing.ranked(all, language: "en").map(\.format)
        #expect(order == [.json, .vtt, .srt, .html, .text])
    }

    @Test func plainTranscriptBeatsCaptionsOfTheSameType() {
        let tracks = [
            FeedTranscriptTrack(url: "https://e.com/a.vtt", type: "text/vtt", rel: "captions"),
            FeedTranscriptTrack(url: "https://e.com/b.vtt", type: "text/vtt"),
        ]
        #expect(TranscriptParsing.ranked(tracks, language: "en").first?.track.url == "https://e.com/b.vtt")
        // Type still outranks rel.
        let mixed = [FeedTranscriptTrack(url: "https://e.com/c.txt", type: "text/plain")] + tracks.prefix(1)
        #expect(TranscriptParsing.ranked(mixed, language: "en").first?.track.url == "https://e.com/a.vtt")
    }

    @Test func languagePreference() {
        let tracks = [
            FeedTranscriptTrack(url: "https://e.com/es.json", type: "application/json", language: "es"),
            FeedTranscriptTrack(url: "https://e.com/en.txt", type: "text/plain", language: "en-US"),
            FeedTranscriptTrack(url: "https://e.com/any.vtt", type: "text/vtt"),
        ]
        #expect(TranscriptParsing.ranked(tracks, language: "en").map(\.track.url) == ["https://e.com/en.txt", "https://e.com/any.vtt", "https://e.com/es.json"])
        #expect(TranscriptParsing.ranked(tracks, language: "es").first?.track.url == "https://e.com/es.json")
        // No match anywhere: untagged, then feed order by type.
        #expect(TranscriptParsing.ranked(tracks, language: "fr").first?.track.url == "https://e.com/any.vtt")
    }

    @Test func unreadableTypesAreDropped() {
        let tracks = [FeedTranscriptTrack(url: "https://e.com/t.pdf", type: "application/pdf")]
        #expect(TranscriptParsing.ranked(tracks, language: "en").isEmpty)
    }

}

@Suite("Transcripts: YouTube")
struct YouTubeCaptionTests {
    private func tracks() throws -> [YouTubeCaptionTrack] {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(TFixture.playerResponse.utf8)) as? [String: Any])
        return YouTubeCaptions.tracks(inPlayerResponse: json)
    }

    @Test func readsTracksAndSkipsTokenGatedOnes() throws {
        let t = try tracks()
        #expect(t.map(\.languageCode) == ["de", "en", "en"])
        #expect(t.map(\.isGenerated) == [false, true, false])
    }

    @Test func trackSelection() throws {
        let t = try tracks()
        // Manual in the user's language.
        #expect(YouTubeCaptions.choose(t, language: "de")?.languageCode == "de")
        // Manual English beats generated in the user's language only when there is no manual in theirs.
        #expect(YouTubeCaptions.choose(t, language: "fr")?.isGenerated == false)
        #expect(YouTubeCaptions.choose(t, language: "en-US")?.baseURL.contains("kind=asr") == false)
        // Generated in the user's language before any other manual track.
        let noEnglishManual = [t[0], t[1]]
        #expect(YouTubeCaptions.choose(noEnglishManual, language: "en")?.isGenerated == true)
        // Anything at all, creator-made first.
        let other = [YouTubeCaptionTrack(baseURL: "a", languageCode: "ja", isGenerated: true), YouTubeCaptionTrack(baseURL: "b", languageCode: "ko", isGenerated: false)]
        #expect(YouTubeCaptions.choose(other, language: "en")?.baseURL == "b")
        #expect(YouTubeCaptions.choose([], language: "en") == nil)
    }

    @Test func timedTextWithEntities() {
        let s = YouTubeCaptions.parseTimedText(TFixture.timedText)
        #expect(s == [
            .init(start: 0.32, text: "Last week, an anonymous mystery model"),
            .init(start: 2.24, text: "that's \"wild\" & fast"),
            .init(start: 4.16, text: "tags stripped > here"),
            .init(start: 7, text: "no duration"),
        ])
    }

    @Test func tracksFromTheWatchPage() {
        let page = """
        <html><script>var ytInitialPlayerResponse = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc\\u0026lang=en","name":{"runs":[{"text":"English [x]"}]},"languageCode":"en"}],"audioTracks":[]}}};
        ytcfg.set({"INNERTUBE_API_KEY":"AIzaSyTEST-key_1","X":1});</script></html>
        """
        let t = YouTubeCaptions.tracks(inWatchPage: page)
        #expect(t == [YouTubeCaptionTrack(baseURL: "https://www.youtube.com/api/timedtext?v=abc&lang=en", languageCode: "en", isGenerated: false)])
        #expect(YouTubeCaptions.innertubeKey(inWatchPage: page) == "AIzaSyTEST-key_1")
        #expect(YouTubeCaptions.tracks(inWatchPage: "<html>no captions</html>").isEmpty)
    }

}

@Suite("Transcripts: fetcher (stubbed HTTP)", .serialized)
struct TranscriptFetcherTests {
    @Test func fetcherPicksTheBestTrackAndResolvesRelativeURLs() async throws {
        TranscriptStub.reset([
            "https://show.example.com/feed.xml": TFixture.episodes,
            "https://show.example.com/1.vtt": "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v Ben>Hello</v>\n",
            "https://show.example.com/1.txt": "plain text should not be used",
        ])
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")
        let source = Source(title: "Show", url: "https://show.example.com", feedUrl: "https://show.example.com/feed.xml", kind: .podcast, group: "podcast")
        let item = Item(sourceId: 1, guid: "ep-1", url: "https://show.example.com/1", title: "One", publishedAt: Date(), audioUrl: "https://cdn.example.com/1.mp3")
        let t = try #require(try await fetcher.transcript(for: item, source: source))
        #expect(t.origin == .podcastFeed)
        #expect(t.segments == [.init(start: 1, speaker: "Ben", text: "Hello")])

        var two = item
        two.guid = "ep-2"
        two.url = "https://show.example.com/2"
        #expect(try await fetcher.transcript(for: two, source: source) == nil)
    }

    @Test func fetcherFallsThroughABrokenTrackAndThrowsWhenAllFail() async throws {
        let source = Source(title: "Show", url: "https://show.example.com", feedUrl: "https://show.example.com/feed.xml", kind: .podcast, group: "podcast")
        let item = Item(sourceId: 1, guid: "ep-1", url: "https://show.example.com/1", title: "One", publishedAt: Date(), audioUrl: "https://cdn.example.com/1.mp3")
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")

        TranscriptStub.reset(["https://show.example.com/feed.xml": TFixture.episodes, "https://show.example.com/1.txt": "From the text file."])
        let t = try #require(try await fetcher.transcript(for: item, source: source))
        #expect(t.segments == [.init(start: nil, text: "From the text file.")])

        TranscriptStub.reset(["https://show.example.com/feed.xml": TFixture.episodes])
        await #expect(throws: HTTPError.self) { try await fetcher.transcript(for: item, source: source) }
    }

    @Test func articlesHaveNoTranscript() async throws {
        TranscriptStub.reset([:])
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")
        let source = Source(title: "Blog", url: "https://b.example.com", feedUrl: "https://b.example.com/feed", kind: .rss, group: "blogs")
        let item = Item(sourceId: 1, guid: "g", url: "https://b.example.com/a", title: "A", publishedAt: Date())
        #expect(try await fetcher.transcript(for: item, source: source) == nil)
        #expect(TranscriptStub.requests().isEmpty)
    }

    @Test func fetcherUsesInnertubeThenDropsFmt() async throws {
        TranscriptStub.reset([
            "https://www.youtube.com/youtubei/v1/player": TFixture.playerResponse,
            "https://www.youtube.com/api/timedtext?v=abc&lang=en": TFixture.timedText,
        ])
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")
        let source = Source(title: "Fireship", url: "https://www.youtube.com/channel/UC1", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1", kind: .youtube, group: "youtube")
        let item = Item(sourceId: 1, guid: "yt:video:abc", url: "https://www.youtube.com/watch?v=abc", title: "V", publishedAt: Date(), videoId: "abc")
        let t = try #require(try await fetcher.transcript(for: item, source: source))
        #expect(t.origin == .youtubeCaptions)
        #expect(t.segments.count == 4)
        #expect(TranscriptStub.requests().count == 2)
    }

    @Test func fetcherFallsBackToTheWatchPage() async throws {
        let page = """
        <script>"INNERTUBE_API_KEY":"KEY123","captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc\\u0026lang=en\\u0026fmt=srv3","languageCode":"en"}]</script>
        """
        TranscriptStub.reset([
            "https://www.youtube.com/watch?v=abc": page,
            "https://www.youtube.com/api/timedtext?v=abc&lang=en": TFixture.timedText,
        ])
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")
        let source = Source(title: "F", url: "https://www.youtube.com/channel/UC1", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1", kind: .youtube, group: "youtube")
        let item = Item(sourceId: 1, guid: "yt:video:abc", url: "https://www.youtube.com/watch?v=abc", title: "V", publishedAt: Date(), videoId: "abc")
        let t = try #require(try await fetcher.transcript(for: item, source: source))
        #expect(t.segments.count == 4)
    }

    @Test func noCaptionsIsNil() async throws {
        TranscriptStub.reset([
            "https://www.youtube.com/youtubei/v1/player": #"{"playabilityStatus":{"status":"OK"}}"#,
            "https://www.youtube.com/watch?v=abc": "<html></html>",
        ])
        let fetcher = DefaultTranscriptFetcher(parser: parser, session: TranscriptStub.session(), language: "en")
        let source = Source(title: "F", url: "https://www.youtube.com/channel/UC1", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1", kind: .youtube, group: "youtube")
        let item = Item(sourceId: 1, guid: "yt:video:abc", url: "https://www.youtube.com/watch?v=abc", title: "V", publishedAt: Date(), videoId: "abc")
        #expect(try await fetcher.transcript(for: item, source: source) == nil)
        var noID = item
        noID.videoId = nil
        #expect(try await fetcher.transcript(for: noID, source: source) == nil)
    }
}

/// URLProtocol stub for the fetcher tests: canned 200 bodies by URL (query string and all), 404 otherwise; logs requests.
/// Shared state, so the suite using it runs serialized.
final class TranscriptStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: String] = [:]
    nonisolated(unsafe) private static var log: [String] = []

    static func reset(_ r: [String: String]) { lock.lock(); routes = r; log = []; lock.unlock() }
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return log }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [TranscriptStub.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.log.append(url)
        let body = Self.routes[url] ?? Self.routes[url.components(separatedBy: "?").first ?? url]
        Self.lock.unlock()
        let res = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])
        if let res { client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
