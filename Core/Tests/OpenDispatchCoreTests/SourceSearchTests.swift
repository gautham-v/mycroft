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

    private func account(_ title: String, _ place: SourcePlace, handle: String, audience: String? = nil) -> SourceSearchResult {
        SourceSearchResult(title: title, subtitle: place.name, feedUrl: "https://\(place.rawValue).example/\(handle)", kind: place == .youtube ? .youtube : place == .x ? .page : .rss,
                           handle: handle, audience: audience, place: place)
    }

    @Test func rankingPutsWhoWasMeantFirst() {
        let ranked = SourceRanking.rank(query: "mkbhd", feeds: [
            result("Waveform: The MKBHD Podcast", .podcast, subtitle: "MKBHD"), result("Unrelated show", .podcast),
        ], accounts: [
            account("Marques Brownlee", .x, handle: "MKBHD"),
            account("Auto Focus", .youtube, handle: "AutoFocus", audience: "1.3M subscribers"),
            account("Marques Brownlee", .youtube, handle: "mkbhd", audience: "21.4M subscribers"),
            account("Marques Brownlee", .bluesky, handle: "mkbhd.com", audience: "212K followers"),
            account("MKBHD Parody", .x, handle: "ParodyMkbhd", audience: "797 followers"),
            account("Marques Brownlee {bot}", .bluesky, handle: "mkbhd-bridged.bsky.social", audience: "5K followers"),
        ])
        #expect(ranked.map(\.handle) == ["mkbhd", "MKBHD", "mkbhd.com", nil, "AutoFocus"])
        #expect(ranked[3].title == "Waveform: The MKBHD Podcast")
    }

    @Test func aHandleUnderAnotherNameIsSomeoneElse() {
        let ranked = SourceRanking.rank(query: "fireship", feeds: [], accounts: [
            account("CHIEF INSPECTOR", .x, handle: "FIRESHIP"),
            account("Fireship", .youtube, handle: "Fireship", audience: "4.32M subscribers"),
            account("Beyond Fireship", .youtube, handle: "beyondfireship", audience: "463K subscribers"),
            account("FireShip", .youtube, handle: "FireShip100", audience: "3 subscribers"),
        ])
        #expect(ranked.map(\.title) == ["Fireship", "Beyond Fireship", "CHIEF INSPECTOR"])
    }

    @Test func theSamePersonRanksWithTheirHandle() {
        let ranked = SourceRanking.rank(query: "karpathy", feeds: [result("Andrej Karpathy blog", subtitle: "karpathy.github.io")], accounts: [
            account("Andrej Karpathy", .x, handle: "karpathy", audience: "4.4M followers"),
            account("Andrej Karpathy", .youtube, handle: "AndrejKarpathy", audience: "1.74M subscribers"),
        ])
        #expect(ranked.map(\.place) == [.x, .youtube, .site])
    }

    @Test func noPlaceTakesTheWholeTop() {
        var accounts = (1...5).map { account("Name \($0)", .youtube, handle: "name\($0)", audience: "\(9 - $0)M subscribers") }
        accounts.append(account("Name six", .bluesky, handle: "six.example", audience: "2K followers"))
        let ranked = SourceRanking.rank(query: "name", feeds: [], accounts: accounts)
        #expect(ranked.prefix(4).map(\.place) == [.youtube, .youtube, .youtube, .bluesky])
        #expect(ranked.count == 6)
    }

    @Test func anAtKeepsOnlyThatHandleAmongAccounts() {
        let ranked = SourceRanking.rank(query: "@simonw", feeds: [result("Simon W notes", subtitle: "simonw.example")], accounts: [
            account("Simon W", .youtube, handle: "SimonW", audience: "8 subscribers"),
            account("Simon Wilson", .youtube, handle: "SimonWilson12", audience: "2.27M subscribers"),
        ])
        #expect(ranked.map(\.title) == ["Simon W", "Simon W notes"])
    }

    @Test func rankingDropsFeedlysCopiesAndXBridges() {
        let url = "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA"
        let channel = SourceSearchResult(title: "Fireship", subtitle: "YouTube", feedUrl: url, kind: .youtube, handle: "Fireship", audience: "4.32M subscribers")
        let ranked = SourceRanking.rank(query: "fireship", feeds: [
            result("Fireship", .youtube, url: url), result("Fireship(@fireship)", url: "https://api.xgo.ing/rss/user/1", site: "https://x.com/fireship"),
        ], accounts: [channel])
        #expect(ranked == [channel])
    }

    @Test func theFallbackStaysWhenNothingMatches() {
        let ranked = SourceRanking.rank(query: "simon willison", feeds: [result("Unrelated", .podcast)], accounts: [])
        #expect(ranked.map(\.title) == ["Unrelated"])
    }

    @Test func kindsFollowThePlace() {
        #expect(SourcePlace.reddit.readType == .post)
        #expect(SourcePlace.bluesky.readType == .post)
        #expect(SourcePlace.youtube.readType == .video)
        #expect(SourcePlace.site.readType == .article)
        #expect(SourceSearchResult(title: "a", subtitle: "b", feedUrl: "c", kind: .podcast).place == .podcast)
    }

    @Test func xCountFromTheSearchFillsInTheProfile() {
        let profile = account("Marques Brownlee", .x, handle: "MKBHD")
        let merged = SourceSearch.mergedXAccounts(profile: profile, named: [
            account("Waveform", .x, handle: "WVFRM", audience: "93K followers"),
            account("Marques Brownlee", .x, handle: "mkbhd", audience: "20M followers"),
        ])
        #expect(merged.map(\.handle) == ["MKBHD", "WVFRM"])
        #expect(merged[0].audience == "20M followers")
        #expect(SourceSearch.mergedXAccounts(profile: nil, named: [profile]) == [profile])
    }

    @Test func redditAddresses() {
        #expect(FeedDetection.redditFeedURL("https://www.reddit.com/r/swift/") == "https://www.reddit.com/r/swift/.rss")
        #expect(FeedDetection.redditFeedURL("https://old.reddit.com/r/swift/top/") == "https://www.reddit.com/r/swift/.rss")
        #expect(FeedDetection.redditFeedURL("https://www.reddit.com/user/spez/") == "https://www.reddit.com/user/spez/.rss")
        #expect(FeedDetection.redditFeedURL("https://www.reddit.com/r/swift/comments/abc/slug/") == nil)
        #expect(FeedDetection.redditFeedURL("https://www.reddit.com/") == nil)
        #expect(SourceSearch.redditCommunity(in: "r/swift") == "swift")
        #expect(SourceSearch.redditCommunity(in: "swift") == nil)
        #expect(SourceSearch.name(in: "r/swift") == "swift")
        #expect(SourceSearch.accountLink("https://www.reddit.com/r/nfl/") == .reddit(community: "nfl"))
        #expect(PostSource.isPostURL("https://www.reddit.com/r/nfl/"))
    }

    @Test func placesWithoutAFeed() {
        #expect(SourceSearch.accountLink("https://www.instagram.com/natgeo/") == .instagram(handle: "natgeo"))
        #expect(SourceSearch.accountLink("https://www.instagram.com/p/abc/") == .noFeed(place: "Instagram"))
        #expect(SourceSearch.accountLink("https://www.threads.net/@zuck") == .noFeed(place: "Threads"))
        #expect(SourceSearch.accountLink("https://www.tiktok.com/@natgeo") == .noFeed(place: "TikTok"))
        #expect(SourceSearch.accountLink("https://bsky.app/profile/simonwillison.net") == .bluesky(handle: "simonwillison.net"))
        #expect(FeedDetection.noFeedPlace("https://stratechery.com/") == nil)
    }

    @Test func detectorSaysWhenAPlaceHasNoFeed() async {
        let detector = DefaultFeedDetector(parser: DefaultFeedParser(), scraper: DefaultPageScraper(), fetch: { _, _ in throw HTTPError.timedOut })
        await #expect(throws: FeedDetectionError("Instagram has no public feed, so its posts can't be followed here.")) {
            _ = try await detector.detect("https://www.instagram.com/natgeo/")
        }
    }

    @Test func blueskySearchAddsFollowerCounts() async throws {
        let accounts = DefaultSocialAccounts(fetch: { url, _ in
            let body = url.contains("searchActors")
                ? #"{"actors":[{"did":"did:plc:abc","handle":"simonwillison.net","displayName":"Simon Willison"}]}"#
                : #"{"profiles":[{"did":"did:plc:abc","handle":"simonwillison.net","displayName":"Simon Willison","avatar":"https://cdn/a.jpg","followersCount":51536}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }, redditPage: { _ in "" })
        let r = try await accounts.bluesky("simon willison")
        #expect(r.first?.feedUrl == "https://bsky.app/profile/did:plc:abc/rss")
        #expect(r.first?.audience == "52K followers")
        #expect(r.first?.place == .bluesky)
    }

    @Test func mastodonSearchLeavesOutBots() async throws {
        let body = #"{"accounts":[{"acct":"simon@simonwillison.net","display_name":"Simon Willison","url":"https://fedi.simonwillison.net/@simon","avatar_static":"https://a/b.png","followers_count":28300,"bot":false},{"acct":"robot","display_name":"Robot","url":"https://x.example/@robot","followers_count":5,"bot":true}]}"#
        let accounts = DefaultSocialAccounts(fetch: { url, _ in
            (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }, redditPage: { _ in "" })
        let r = try await accounts.mastodon("simon willison")
        #expect(r.map(\.feedUrl) == ["https://fedi.simonwillison.net/@simon.rss"])
        #expect(r.first?.handle == "simon@simonwillison.net")
    }

    @Test func redditCommunitiesPage() {
        let html = """
            <div class="thing subreddit"><a class="title" href="https://www.reddit.com/r/nfl/">r/nfl: NFL: National Football League Discussion</a></div>
            <div class="thing subreddit"><a class="title" href="https://www.reddit.com/user/nfl/">u/nfl: NFL</a></div>
            <div class="thing subreddit over18"><a class="title" href="https://www.reddit.com/r/adult/">r/adult: Adult</a></div>
            <div class="thing subreddit"><a class="title" href="https://www.reddit.com/r/NFL_Draft/">r/NFL_Draft</a></div>
            """
        let found = DefaultSocialAccounts.communities(inSearch: html)
        #expect(found.map(\.title) == ["r/nfl", "r/NFL_Draft"])
        #expect(found[0].subtitle == "NFL: National Football League Discussion")
        #expect(found[0].feedUrl == "https://www.reddit.com/r/nfl/.rss")
        #expect(found[1].subtitle == "Community")
    }

    @Test func instagramPreview() {
        let html = #"<meta property="og:title" content="National Geographic (&#064;natgeo) &#x2022; Instagram photos and videos"><meta property="og:description" content="268M Followers, 196 Following, 32K Posts"><meta property="og:image" content="https://cdn/a.jpg">"#
        let r = DefaultSocialAccounts.instagramProfile(html: html)
        #expect(r?.title == "National Geographic")
        #expect(r?.handle == "natgeo")
        #expect(r?.audience == "268M followers")
        #expect(r?.canFollow == false)
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

@Suite("YouTube embed check")
struct YouTubeEmbedCheckTests {
    @Test func embedPageStatus() {
        #expect(DefaultYouTubeEmbedCheck.isPlayable(embedPage: #"x\"previewPlayabilityStatus\":{\"status\":\"UNPLAYABLE\",\"reason\":\"Video unavailable\"}"#) == false)
        #expect(DefaultYouTubeEmbedCheck.isPlayable(embedPage: #"x"previewPlayabilityStatus":{"status":"OK","playableInEmbed":true}"#) == true)
        #expect(DefaultYouTubeEmbedCheck.isPlayable(embedPage: #""previewPlayabilityStatus":{"status":"LOGIN_REQUIRED"}"#) == nil)
        #expect(DefaultYouTubeEmbedCheck.isPlayable(embedPage: "<html></html>") == nil)
    }

    @Test func channelAsksAboutItsNewestVideo() async {
        let check = DefaultYouTubeEmbedCheck(fetch: { url, _ in
            let body = url.contains("/feeds/")
                ? "<feed><entry><yt:videoId>newest</yt:videoId></entry><entry><yt:videoId>older</yt:videoId></entry></feed>"
                : (url.hasSuffix("/embed/newest") ? #""previewPlayabilityStatus":{"status":"UNPLAYABLE"}"# : #""previewPlayabilityStatus":{"status":"OK"}"#)
            return (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        #expect(await check.isPlayable(channelID: "UCx") == false)
        #expect(await check.isPlayable(videoID: "older") == true)
    }
}
