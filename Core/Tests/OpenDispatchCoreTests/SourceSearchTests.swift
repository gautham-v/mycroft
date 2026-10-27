import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Source search")
struct SourceSearchTests {
    /// Answers Feedly and iTunes requests with canned JSON (nil = that provider fails).
    private func search(feedly: String?, itunes: String?, now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> DefaultSourceSearch {
        DefaultSourceSearch(fetch: { url in
            let body = url.contains("feedly.com") ? feedly : itunes
            guard let body else { throw HTTPError.timedOut }
            let res = HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), res)
        }, now: { now })
    }

    private let feedly = """
        {"results":[
          {"feedId":"feed/https://stratechery.com/feed/","title":"Stratechery by Ben Thompson","website":"https://stratechery.com","lastUpdated":1789000000000},
          {"feedId":"feed/https://www.youtube.com/playlist?list=UUsBjURrPoezykLs9EqgamOA","title":"Fireship (uploads) on YouTube","website":"https://www.youtube.com/playlist?list=UUsBjURrPoezykLs9EqgamOA"},
          {"feedId":"feed/http://gdata.youtube.com/feeds/base/users/TEDtalksDirector/uploads","title":"TED (uploads) on YouTube"},
          {"feedId":"feed/https://old.example.com/rss","title":"Gone quiet","website":"https://old.example.com","lastUpdated":1500000000000},
          {"feedId":"feed/https://feeds.transistor.fm/acquired/","title":"Acquired (feed)","website":"https://acquired.fm"}
        ]}
        """
    private let itunes = """
        {"resultCount":1,"results":[{"collectionName":"Acquired","artistName":"Ben Gilbert and David Rosenthal",
          "feedUrl":"https://feeds.transistor.fm/acquired","artworkUrl100":"https://img.example.com/a.jpg",
          "collectionViewUrl":"https://podcasts.apple.com/us/podcast/acquired/id1050462261"}]}
        """

    @Test func mergesFeedsAndPodcasts() async throws {
        let results = try await search(feedly: feedly, itunes: itunes).search("acquired")
        // Matches on name first, then (with so few) the rest in provider order.
        #expect(results.map(\.title) == ["Acquired", "Stratechery by Ben Thompson", "Fireship"])
        // The podcast entry wins over Feedly's copy of the same feed.
        #expect(results[0].kind == .podcast)
        #expect(results[0].imageUrl == "https://img.example.com/a.jpg")
        #expect(results[1].subtitle == "stratechery.com")
        #expect(results[1].kind == .rss)
        // Uploads playlist → channel feed.
        #expect(results[2].kind == .youtube)
        #expect(results[2].feedUrl == "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA")
        #expect(results[2].subtitle == "YouTube")
    }

    @Test func nameMatchesAlternateBeforeTheRest() {
        func r(_ title: String, _ kind: SourceKind) -> SourceSearchResult {
            SourceSearchResult(title: title, subtitle: "x", feedUrl: "https://\(title.filter(\.isLetter)).example/\(kind)", kind: kind)
        }
        let merged = DefaultSourceSearch.merge(query: "Simon Willison",
            feeds: [r("Simon Willison's Weblog", .rss), r("Simon Willison TIL", .rss)],
            podcasts: [r("Lenny's Podcast", .podcast), r("Simon Willison on AI", .podcast)])
        // Three name matches, so the guest appearance is left out.
        #expect(merged.map(\.title) == ["Simon Willison's Weblog", "Simon Willison on AI", "Simon Willison TIL"])
    }

    @Test func oneProviderFailingStillReturnsTheOther() async throws {
        let results = try await search(feedly: nil, itunes: itunes).search("acquired")
        #expect(results.map(\.title) == ["Acquired"])
    }

    @Test func everyProviderFailingThrows() async {
        await #expect(throws: (any Error).self) { try await search(feedly: nil, itunes: nil).search("x") }
    }

    @Test func blankQueryIsEmpty() async throws {
        #expect(try await search(feedly: nil, itunes: nil).search("  ").isEmpty)
    }

    @Test func linksInPastedText() {
        #expect(SourceSearch.links(in: "stratechery.com") == ["https://stratechery.com/"])
        #expect(SourceSearch.links(in: "daringfireball.net\nyoutube.com/@fireship, platformer.news") ==
                ["https://daringfireball.net/", "https://youtube.com/@fireship", "https://platformer.news/"])
        #expect(SourceSearch.links(in: "simon willison").isEmpty)
        #expect(SourceSearch.links(in: "the verge.com").isEmpty)
    }
}

@Suite("First run")
struct FirstRunTests {
    @Test func newDatabaseStartsEmpty() async throws {
        let db = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration()))
        let (sources, folders) = try await db.sourcesAndFolders()
        #expect(sources.isEmpty)
        #expect(folders.isEmpty)
    }
}
