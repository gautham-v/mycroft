import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Opened links")
struct OpenedLinksTests {
    @Test func youTubeVideoIDs() {
        let id = "iniryju23Sk"
        for url in [
            "https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?v=\(id)&t=42s", "https://m.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abc", "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/live/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
        ] {
            #expect(OpenedLinks.youTubeVideoID(url) == id, "\(url)")
        }
        for url in ["https://www.youtube.com/@aiDotEngineer", "https://www.youtube.com/watch?v=short", "https://example.com/watch?v=\(id)"] {
            #expect(OpenedLinks.youTubeVideoID(url) == nil, "\(url)")
        }
        #expect(OpenedLinks.canonicalURL("https://youtu.be/\(id)?t=3", videoID: id) == "https://www.youtube.com/watch?v=\(id)")
        #expect(OpenedLinks.canonicalURL("https://example.com/a?x=1#section", videoID: nil) == "https://example.com/a?x=1")
    }

    @Test func youTubeWatchMeta() {
        let html = #"<script>var x = {"videoDetails":{"videoId":"iniryju23Sk","lengthSeconds":"1136","shortDescription":"Line one\nLine \"two\"","ownerChannelName":"AI Engineer"}};</script>"#
        let m = PageScraping.youTubeWatchMeta(html: html)
        #expect(m.channel == "AI Engineer")
        #expect(m.description == "Line one\nLine \"two\"")
        #expect(m.durationSec == 1136)
    }

    @Test func storedOutsideTheFeedAndTheSourceList() async throws {
        let db = try Fixture.db()
        let blog = try Fixture.source(db)
        try Fixture.items(db, sourceId: blog.id, Fixture.parsed(1))
        let link = try await db.insertOpenedLink(ParsedItem(
            guid: "https://github.com/gautham-v/opendispatch", url: "https://github.com/gautham-v/opendispatch",
            title: "OpenDispatch", publishedAt: Fixture.base))
        let video = try await db.insertOpenedLink(ParsedItem(
            guid: "https://www.youtube.com/watch?v=iniryju23Sk", url: "https://www.youtube.com/watch?v=iniryju23Sk",
            title: "A video", author: "AI Engineer", publishedAt: Fixture.base, videoId: "iniryju23Sk"))
        let episode = try await db.insertOpenedLink(ParsedItem(
            guid: "https://podcasts.apple.com/us/podcast/id1?i=2", url: "https://podcasts.apple.com/us/podcast/a-show/id1?i=2",
            title: "An episode", author: "A Show", publishedAt: Fixture.base, audioUrl: "https://cdn.example.com/2.mp3"))
        let file = try await db.insertOpenedLink(OpenedLinks.audioItem(url: "https://cdn.example.com/talks/keynote_2026.mp3"))

        // Shown as their site or channel, in a source of the right kind.
        #expect(link.source.title == "github.com")
        #expect(link.source.host == "github.com")
        #expect(link.source.kind == .page)
        #expect(video.source.title == "AI Engineer")
        #expect(video.source.kind == .youtube)
        #expect(episode.source.title == "A Show")
        #expect(episode.source.host == "podcasts.apple.com")
        #expect(episode.source.kind == .podcast)
        #expect(file.source.title == "cdn.example.com")
        #expect(file.source.feedUrl == OpenedLinks.episodesFeedURL)

        // Not subscriptions, and not in the feed until saved.
        #expect(try await db.sources().map(\.id) == [blog.id])
        #expect(try await db.items(ItemQuery(view: .all)).items.map(\.item.guid) == ["i0"])
        #expect(try await db.items(ItemQuery(view: .video)).items.isEmpty)
        #expect(try await db.items(ItemQuery(view: .podcasts)).items.isEmpty)
        try await db.setSaved(itemId: video.id, saved: true)
        try await db.setSaved(itemId: episode.id, saved: true)
        #expect(try await db.items(ItemQuery(view: .saved)).items.map(\.id).sorted() == [video.id, episode.id].sorted())
        #expect(try await db.counts().views[.all] == 1)

        // Opening the same link again finds the stored one.
        #expect(try await db.openedLink(feedUrl: OpenedLinks.linksFeedURL, url: link.item.url)?.id == link.id)
    }

    @Test func prunedFourteenDaysAfterOpening() async throws {
        let db = try Fixture.db()
        let old = Fixture.base.addingTimeInterval(-60 * 86_400)
        let page = ParsedItem(guid: "https://example.com/old", url: "https://example.com/old", title: "Old", publishedAt: old)
        let episode = ParsedItem(guid: "https://cdn.example.com/old.mp3", url: "https://cdn.example.com/old.mp3", title: "Old",
                                 publishedAt: old, audioUrl: "https://cdn.example.com/old.mp3")
        let opened = try await db.writer.write { d in
            [try Queries.insertOpenedLink(d, page, now: Fixture.base), try Queries.insertOpenedLink(d, episode, now: Fixture.base)]
        }
        // Published long ago but opened now: kept.
        #expect(try await db.pruneOldItems(before: Retention.cutoff(now: Fixture.base)) == 0)
        // Two weeks after it was opened: gone.
        #expect(try await db.pruneOldItems(before: Retention.cutoff(now: Fixture.base.addingTimeInterval(15 * 86_400))) == 2)
        for item in opened { #expect(try await db.feedItem(id: item.id) == nil) }
    }

    @Test func eachKindOfLinkHasItsHolder() {
        let page = ParsedItem(guid: "g", url: "https://example.com", title: "t", publishedAt: Fixture.base)
        #expect(OpenedLinks.feedURL(for: page) == OpenedLinks.linksFeedURL)
        var video = page
        video.videoId = "iniryju23Sk"
        #expect(OpenedLinks.feedURL(for: video) == OpenedLinks.videosFeedURL)
        var episode = page
        episode.audioUrl = "https://cdn.example.com/a.mp3"
        #expect(OpenedLinks.feedURL(for: episode) == OpenedLinks.episodesFeedURL)
        for url in [OpenedLinks.linksFeedURL, OpenedLinks.videosFeedURL, OpenedLinks.episodesFeedURL] {
            #expect(OpenedLinks.isOpenedLinks(feedUrl: url))
            #expect(OpenedLinks.template(feedUrl: url, now: Fixture.base)?.feedUrl == url)
        }
        #expect(OpenedLinks.template(feedUrl: OpenedLinks.episodesFeedURL, now: Fixture.base)?.kind == .podcast)
        #expect(!OpenedLinks.isOpenedLinks(feedUrl: "https://example.com/feed"))
    }

    @Test func directAudioLinks() {
        for url in [
            "https://cdn.example.com/talk.mp3", "https://cdn.example.com/a/talk.M4A?token=abc", "https://example.com/pod.m4b",
            "https://example.com/x.ogg#t=30", "https://example.com/x.opus", "https://example.com/x.wav", "https://example.com/x.flac", "https://example.com/x.aac",
        ] {
            #expect(OpenedLinks.isAudioURL(url), "\(url)")
        }
        for url in [
            "https://example.com/talk", "https://example.com/talk.html", "https://example.com/mp3", "https://example.com/video.mp4",
            "https://example.com/?file=talk.mp3", "https://example.com/dir.mp3/",
        ] {
            #expect(!OpenedLinks.isAudioURL(url), "\(url)")
        }
        #expect(OpenedLinks.isAudioContentType("audio/mpeg"))
        #expect(OpenedLinks.isAudioContentType("Audio/MP4; codecs=mp4a"))
        #expect(!OpenedLinks.isAudioContentType("text/html; charset=utf-8"))
        #expect(!OpenedLinks.isAudioContentType("application/octet-stream"))
        #expect(!OpenedLinks.isAudioContentType(nil))
    }

    @Test func audioItemTitleComesFromTheFileName() {
        let item = OpenedLinks.audioItem(url: "https://cdn.example.com/talks/Keynote_2026-final%20cut.mp3?sig=1", now: Fixture.base)
        #expect(item.title == "Keynote 2026 final cut")
        #expect(item.guid == "https://cdn.example.com/talks/Keynote_2026-final%20cut.mp3?sig=1")
        #expect(item.audioUrl == item.url)
        #expect(item.publishedAt == Fixture.base)
        #expect(item.author == nil)
        // No usable name: the host.
        #expect(OpenedLinks.audioItem(url: "https://cdn.example.com/%20.mp3").title == "cdn.example.com")
    }

    @Test func pageTitlesLoseTheirSiteTail() {
        let apple = "https://podcasts.apple.com/us/podcast/some-show/id1627920305"
        #expect(OpenedLinks.cleanedTitle("\u{200E}Lenny's Podcast: Product | Career | Growth on Apple Podcasts", url: apple)
                == "Lenny's Podcast: Product | Career | Growth")
        #expect(OpenedLinks.cleanedTitle("An episode - Apple Podcasts", url: apple) == "An episode")
        let spotify = "https://open.spotify.com/episode/6mYNtYPOtQeOFVQJxsKJcF"
        #expect(OpenedLinks.cleanedTitle("The Joe Rogan Experience | Listen to the Podcast on Spotify", url: spotify) == "The Joe Rogan Experience")
        #expect(OpenedLinks.cleanedTitle("An Episode - Podcast on Spotify", url: spotify) == "An Episode")
        #expect(OpenedLinks.cleanedTitle("An Episode", url: spotify) == "An Episode")
        // The shell a player serves without a login is no title.
        #expect(OpenedLinks.cleanedTitle("Spotify \u{2013} Web Player", url: spotify) == nil)
        #expect(OpenedLinks.cleanedTitle("Spotify", url: spotify) == nil)
        // Other sites keep theirs.
        #expect(OpenedLinks.cleanedTitle(" A post | Apple Podcasts ", url: "https://example.com/a") == "A post | Apple Podcasts")
    }

    @Test func savedLinkSyncsWithoutItsSource() async throws {
        let a = try Fixture.db()
        let link = try await a.insertOpenedLink(ParsedItem(
            guid: "https://example.com/post", url: "https://example.com/post", title: "Post", publishedAt: Fixture.base))
        try await a.setSaved(itemId: link.id, saved: true)
        let local = try await a.reader.read { d in try SyncStore.localRecords(d, readwiseToken: nil) }
        #expect(!local.values.contains { $0.type == .source })
        let saved = try #require(local.values.first { $0.type == .savedItem })

        // Another device has never opened a link: the holder source is created for it.
        let b = try Fixture.db()
        try await b.writer.write { d in
            _ = try SyncStore.apply(d, modifications: [.init(record: saved, systemFields: nil)], deletions: [])
        }
        let there = try await b.items(ItemQuery(view: .saved)).items
        #expect(there.map(\.item.title) == ["Post"])
        #expect(there.first?.source.title == "example.com")
        #expect(try await b.sources().isEmpty)
    }

    @Test func savedEpisodeSyncsIntoItsOwnHolder() async throws {
        let a = try Fixture.db()
        let episode = try await a.insertOpenedLink(ParsedItem(
            guid: "https://podcasts.apple.com/us/podcast/id1?i=2", url: "https://podcasts.apple.com/us/podcast/a-show/id1?i=2",
            title: "An episode", author: "A Show", publishedAt: Fixture.base, durationSec: 600, audioUrl: "https://cdn.example.com/2.mp3"))
        try await a.setSaved(itemId: episode.id, saved: true)
        let local = try await a.reader.read { d in try SyncStore.localRecords(d, readwiseToken: nil) }
        #expect(!local.values.contains { $0.type == .source })
        let saved = try #require(local.values.first { $0.type == .savedItem })

        let b = try Fixture.db()
        try await b.writer.write { d in
            _ = try SyncStore.apply(d, modifications: [.init(record: saved, systemFields: nil)], deletions: [])
        }
        let there = try #require(try await b.items(ItemQuery(view: .saved)).items.first)
        #expect(there.source.feedUrl == OpenedLinks.episodesFeedURL)
        #expect(there.source.kind == .podcast)
        #expect(there.source.title == "A Show")
        #expect(there.item.audioUrl == "https://cdn.example.com/2.mp3")
        #expect(there.item.durationSec == 600)
        #expect(try await b.sources().isEmpty)
    }
}
