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

    private func result(_ title: String, _ kind: SourceKind = .rss, url: String? = nil, site: String? = nil, subtitle: String = "example.com",
                        handle: String? = nil, audience: String? = nil) -> SourceSearchResult {
        SourceSearchResult(title: title, subtitle: subtitle, feedUrl: url ?? "https://\(title.filter(\.isLetter).lowercased()).example/feed", siteUrl: site,
                           kind: kind, handle: handle, audience: audience)
    }

    @Test func sectionsSortByPlaceAndAllKeepsTheFirstChannels() {
        let x = result("Marques Brownlee", .page, url: "https://x.com/MKBHD", handle: "MKBHD")
        let channels = ["One", "Two", "Three", "Four"].map { result($0, .youtube, handle: $0, audience: "2M subscribers") }
        let s = SourceSearch.sections(query: "mkbhd", feeds: [
            result("MKBHD blog"), result("MKBHD show", .podcast), result("MKBHD notes"), result("Unrelated", .podcast),
        ], channels: channels, xAccounts: [x])
        #expect(s.x == [x])
        #expect(s.youtube.count == 4)
        #expect(s.sites.map(\.title) == ["MKBHD blog", "MKBHD notes"])
        // An account matched, so the show that doesn't carry the name is left out.
        #expect(s.podcasts.map(\.title) == ["MKBHD show"])
        #expect(s.all.map(\.title) == ["Marques Brownlee", "One", "Two", "Three", "MKBHD blog", "MKBHD show", "MKBHD notes"])
    }

    @Test func allKeepsTheFirstAccounts() {
        let accounts = ["A", "B", "C", "D"].map { result($0, .page, url: "https://x.com/\($0)", handle: $0) }
        let s = SourceSearch.sections(query: "name", feeds: [], channels: [], xAccounts: accounts)
        #expect(s.x.count == 4)
        #expect(s.all.map(\.title) == ["A", "B", "C"])
    }

    @Test func sectionsKeepTheFallbackWithoutAnAccount() {
        let s = SourceSearch.sections(query: "simon willison", feeds: [result("Unrelated", .podcast)], channels: [], xAccounts: [])
        #expect(s.podcasts.map(\.title) == ["Unrelated"])
    }

    @Test func sectionsDropTinyChannelsUnlessTheHandleIsExact() {
        let channels = [
            result("Fireship", .youtube, handle: "Fireship", audience: "4.32M subscribers"),
            result("FireShip", .youtube, handle: "FireShip100", audience: "3 subscribers"),
            result("Isracode", .youtube, handle: "fireshipai", audience: "29.4K subscribers"),
            result("Silent", .youtube, handle: "silent"),
        ]
        #expect(SourceSearch.sections(query: "fireship", feeds: [], channels: channels, xAccounts: []).youtube.map(\.title) == ["Fireship", "Isracode"])
        #expect(SourceSearch.sections(query: "@fireshipai", feeds: [], channels: channels, xAccounts: []).youtube.map(\.title) == ["Isracode"])
        let tiny = [result("Simon W", .youtube, handle: "SimonW", audience: "8 subscribers")]
        #expect(SourceSearch.sections(query: "@simonw", feeds: [], channels: tiny, xAccounts: []).youtube.map(\.title) == ["Simon W"])
    }

    @Test func sectionsDropFeedlysCopiesAndXBridges() {
        let url = "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA"
        let channel = result("Fireship", .youtube, url: url, handle: "Fireship", audience: "4.32M subscribers")
        let s = SourceSearch.sections(query: "fireship", feeds: [
            result("Fireship", .youtube, url: url), result("Fireship(@fireship)", url: "https://api.xgo.ing/rss/user/1", site: "https://x.com/fireship"),
        ], channels: [channel], xAccounts: [])
        #expect(s.youtube == [channel])
        #expect(s.sites.isEmpty)
    }

    @Test func subscriberCounts() {
        #expect(SourceSearch.subscriberCount("21.4M subscribers") == 21_400_000)
        #expect(SourceSearch.subscriberCount("589 subscribers") == 589)
        #expect(SourceSearch.subscriberCount("1,234 subscribers") == 1234)
        #expect(SourceSearch.subscriberCount("No subscribers") == nil)
        #expect(SourceSearch.subscriberCount(nil) == nil)
    }

    @Test func handlesInAQuery() {
        #expect(SourceSearch.xHandle(in: "@simonw") == "simonw")
        #expect(SourceSearch.xHandle(in: " karpathy ") == "karpathy")
        #expect(SourceSearch.xHandle(in: "simon willison") == nil)
        #expect(SourceSearch.xHandle(in: "node.js") == nil)
        #expect(SourceSearch.xHandle(in: "averyveryverylonghandle") == nil)
        #expect(SourceSearch.name(in: "@simonw") == "simonw")
    }

    @Test func accountLinks() {
        #expect(SourceSearch.accountLink("https://x.com/karpathy") == .x(handle: "karpathy"))
        #expect(SourceSearch.accountLink("https://twitter.com/karpathy/") == .x(handle: "karpathy"))
        #expect(SourceSearch.accountLink("https://x.com/karpathy/status/123") == nil)
        #expect(SourceSearch.accountLink("https://youtube.com/@mkbhd") == .youtubeHandle("mkbhd"))
        #expect(SourceSearch.accountLink("https://www.youtube.com/@mkbhd/videos") == .youtubeHandle("mkbhd"))
        #expect(SourceSearch.accountLink("https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA") == .youtubeChannel(id: "UCsBjURrPoezykLs9EqgamOA"))
        #expect(SourceSearch.accountLink("https://www.youtube.com/watch?v=abc") == nil)
        #expect(SourceSearch.accountLink("https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA") == nil)
        #expect(SourceSearch.accountLink("https://stratechery.com/") == nil)
    }

    @Test func channelKeepsItsHandleAndCount() throws {
        let r = try #require(DefaultExploreSearch.channel([
            "channelId": "UCBJycsmduvYEL83R_U4JriQ", "title": ["simpleText": "Marques Brownlee"],
            "subscriberCountText": ["simpleText": "@mkbhd"], "videoCountText": ["simpleText": "21.4M subscribers"],
        ]))
        #expect(r.handle == "mkbhd")
        #expect(r.audience == "21.4M subscribers")
        #expect(r.subtitle == "YouTube · 21.4M subscribers")
        #expect(!r.isXAccount)
    }

    @Test func xProfilePage() throws {
        let html = """
            <html><head><title>Andrej Karpathy (@karpathy) / X</title>
            <meta property="og:description" content="4403881 followers · 1144 following. Earth.">
            <meta property="og:image" content="https://pbs.twimg.com/profile_images/1/a_400x400.jpg"></head></html>
            """
        let r = try #require(XAccounts.profile(html: html, handle: "KARPATHY"))
        #expect(r.title == "Andrej Karpathy")
        #expect(r.handle == "karpathy")
        #expect(r.audience == "4.4M followers")
        #expect(r.feedUrl == "https://x.com/karpathy")
        #expect(r.imageUrl == "https://pbs.twimg.com/profile_images/1/a_400x400.jpg")
        #expect(r.isXAccount)
        // A page without the count has none, and any other page isn't the account.
        let bio = #"<title>Marques &amp; Co (@MKBHD) / X</title><meta property="og:description" content="Web Video Producer">"#
        let m = try #require(XAccounts.profile(html: bio, handle: "mkbhd"))
        #expect(m.title == "Marques & Co")
        #expect(m.audience == nil)
        #expect(XAccounts.profile(html: "<title>Log in to X / X</title>", handle: "login") == nil)
        #expect(XAccounts.profile(html: html, handle: "someoneelse") == nil)
    }

    @Test func xProfileAnswers() async throws {
        func accounts(_ status: Int, _ body: String) -> DefaultXAccounts {
            DefaultXAccounts(fetch: { url in
                (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            })
        }
        let found = try await accounts(200, "<title>Simon Willison (@simonw) / X</title>").profile(handle: "simonw")
        #expect(found?.title == "Simon Willison")
        #expect(try await accounts(404, "<title>User Profile Not Found - X | 404 Error</title>").profile(handle: "nobody") == nil)
        await #expect(throws: (any Error).self) { try await accounts(503, "").profile(handle: "simonw") }
    }

    @Test func followerWording() {
        #expect(XAccounts.followers(4_403_881) == "4.4M followers")
        #expect(XAccounts.followers(247_511) == "248K followers")
        #expect(XAccounts.followers(1_234) == "1.2K followers")
        #expect(XAccounts.followers(1) == "1 follower")
    }

    @Test func xPeopleSearchAnswer() throws {
        let json = """
            {"data":{"search_by_raw_query":{"search_timeline":{"timeline":{"instructions":[{"type":"TimelineAddEntries","entries":[
              {"entryId":"user-12497","content":{"itemContent":{"user_results":{"result":{"__typename":"User",
                "core":{"name":"Simon Willison","screen_name":"simonw"},
                "avatar":{"image_url":"https://pbs.twimg.com/profile_images/1/a_normal.jpg"},
                "relationship_counts":{"followers":247511,"following":5677}}}}}},
              {"entryId":"user-99","content":{"itemContent":{"user_results":{"result":{"__typename":"User",
                "legacy":{"name":"Older Shape","screen_name":"older","profile_image_url_https":"https://pbs.twimg.com/b_normal.png"}}}}}},
              {"entryId":"user-12497","content":{"itemContent":{"user_results":{"result":{"core":{"name":"Simon Willison","screen_name":"simonw"}}}}}},
              {"entryId":"cursor-bottom-1","content":{"value":"x"}}
            ]}]}}}}}
            """
        let found = XPages.accounts(inTimeline: Data(json.utf8))
        #expect(found.map(\.handle) == ["simonw", "older"])
        #expect(found[0].title == "Simon Willison")
        #expect(found[0].audience == "248K followers")
        #expect(found[0].imageUrl == "https://pbs.twimg.com/profile_images/1/a_bigger.jpg")
        #expect(found[0].feedUrl == "https://x.com/simonw")
        #expect(found[1].title == "Older Shape")
        #expect(XPages.peopleSearchURL("simon willison").hasSuffix("&f=user"))
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
