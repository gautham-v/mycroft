import Foundation
import Testing
@testable import OpenDispatchCore

/// Manual live check of podcast support against real feeds (network). Skipped unless
/// OPENDISPATCH_LIVE_PODCASTS=1. Optional OPENDISPATCH_LIVE_PODCAST_DIR=<dir> also parses every *.xml in it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_LIVE_PODCASTS"] == "1"))
struct PodcastLiveTests {
    static let feeds = [
        "https://feeds.simplecast.com/54nAGcIl",          // The Daily
        "https://lexfridman.com/feed/podcast/",
        "https://podcasts.apple.com/us/podcast/the-daily/id1200361736",
        "https://feeds.npr.org/510289/podcast.xml",
    ]

    @Test(arguments: feeds) func detectAndParse(_ input: String) async throws {
        let parser = DefaultFeedParser()
        let detector = DefaultFeedDetector(parser: parser, scraper: DefaultPageScraper())
        let start = Date()
        let detected = try await detector.detect(input)
        print("[live] \(input) -> kind=\(detected.kind) group=\(detected.group) title=\(detected.title) feed=\(detected.feedUrl) icon=\(detected.iconUrl ?? "-") in \(Date().timeIntervalSince(start))s")
        #expect(detected.kind == .podcast)
        #expect(detected.iconUrl != nil)

        let (data, _) = try await HTTP.fetch(detected.feedUrl, timeout: 30, headers: ["Accept": HTTP.feedAccept])
        let feed = try parser.parse(data, kind: .podcast, feedURL: detected.feedUrl)
        let withAudio = feed.items.filter { $0.audioUrl != nil }
        let withDuration = feed.items.filter { $0.durationSec != nil }
        print("[live]   items=\(feed.items.count) audio=\(withAudio.count) duration=\(withDuration.count)")
        for e in feed.items.prefix(2) {
            print("[live]   - \(e.title) | url=\(e.url) | audio=\(e.audioUrl ?? "-") | dur=\(e.durationSec.map(String.init) ?? "-") | thumb=\(e.thumbnailUrl ?? "-")")
            let html = parser.itemHTML(in: data, guid: e.guid, url: e.url)
            print("[live]     notes=\(html?.count ?? 0) chars")
        }
        #expect(feed.isPodcast)
        #expect(withAudio.count == feed.items.count)
        #expect(withDuration.count * 10 >= feed.items.count * 9)
    }

    @Test func localFeeds() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENDISPATCH_LIVE_PODCAST_DIR"] else { return }
        let parser = DefaultFeedParser()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".xml") }.sorted()
        for f in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f))
            let start = Date()
            let feed = try parser.parse(data, kind: .rss, feedURL: "https://example.com/\(f)")
            let audio = feed.items.filter { $0.audioUrl != nil }.count
            let dur = feed.items.filter { $0.durationSec != nil }.count
            let first = feed.items.first
            print("[local] \(f) podcast=\(feed.isPodcast) items=\(feed.items.count) audio=\(audio) dur=\(dur) img=\(feed.imageUrl ?? "-") \(String(format: "%.2f", Date().timeIntervalSince(start)))s first=\(first?.title ?? "-") dur=\(first?.durationSec ?? -1) url=\(first?.url ?? "-")")
            #expect(feed.isPodcast, "\(f)")
        }
    }
}

struct PodcastAuthorTests {
    @Test func displayAuthor() {
        typealias S = FeedParsingSupport
        #expect(S.displayAuthor("thedaily@nytimes.com (The New York Times)", fallback: nil) == "The New York Times")
        #expect(S.displayAuthor("host@show.fm", fallback: "Show Host") == "Show Host")
        #expect(S.displayAuthor("host@show.fm", fallback: nil) == "host@show.fm")
        #expect(S.displayAuthor("Lex Fridman", fallback: "Other") == "Lex Fridman")
        #expect(S.displayAuthor("  ", fallback: "Itunes Name") == "Itunes Name")
        #expect(S.displayAuthor(nil, fallback: nil) == nil)
    }

    @Test func episodeAuthorPrefersNameOverEmail() throws {
        let xml = #"""
        <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title><link>https://show.example.com</link><itunes:author>Show Co</itunes:author>
        <item><guid>a</guid><title>One</title><author>news@show.example.com (Show Newsroom)</author><enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg" length="1"/><itunes:duration>12:34</itunes:duration></item>
        <item><guid>b</guid><title>Two</title><author>news@show.example.com</author><itunes:author>Jane Host</itunes:author><enclosure url="https://cdn.example.com/2.mp3" type="audio/mpeg" length="1"/></item>
        <item><guid>c</guid><title>Three</title><itunes:author>Jane Host</itunes:author><enclosure url="https://cdn.example.com/3.mp3" type="audio/mpeg" length="1"/></item>
        </channel></rss>
        """#
        let feed = try DefaultFeedParser().parse(Data(xml.utf8), kind: .rss, feedURL: "https://show.example.com/feed")
        #expect(feed.isPodcast)
        #expect(feed.items.map(\.author) == ["Show Newsroom", "Jane Host", "Jane Host"])
        #expect(feed.items.first?.durationSec == 754)
        #expect(feed.items.first?.audioUrl == "https://cdn.example.com/1.mp3")
    }
}
