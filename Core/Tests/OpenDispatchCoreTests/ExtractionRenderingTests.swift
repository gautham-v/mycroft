import Foundation
import Testing
@testable import OpenDispatchCore

/// Rendering defects found by comparing the reader with the original pages (Yahoo, MSN, NPR, Ars Technica, CBS, ESPN,
/// Fox Sports, AP, The Verge, 404 Media and others).
@Suite("Extraction: rendering review")
struct ExtractionRenderingTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    @Test func streamedBoundaryContentIsMovedIntoPlace() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><!--$?--><template id="B:1"></template>
        <div aria-busy="true">Loading...</div><!--/$--></article>
        <div hidden id="S:1"><div class="content-body">\(p)</div></div>
        <script>$RC("B:1","S:1")</script></body></html>
        """
        let doc = try #require(ExtractionDOM.parseDocument(html, baseURI: "https://e.com/"))
        ArticlePasses.resolveStreamedBoundaries(doc)
        let article = try #require(ExtractionDOM.first(doc, "article"))
        #expect(ExtractionDOM.text(article).contains("The reader shows"))
        #expect(!ExtractionDOM.text(article).contains("Loading"))
        #expect(ExtractionDOM.first(doc, "[hidden]") == nil)
    }

    @Test func msnArticleComesFromTheContentAPI() throws {
        #expect(MSNArticle.apiURL("https://www.msn.com/en-us/sports/football/eagles/ar-AA2glIrH")
                == "https://assets.msn.com/content/view/v2/Detail/en-us/AA2glIrH")
        #expect(MSNArticle.apiURL("https://www.msn.com/en-us/news/other/cte/vi-AA2glw6G") == nil)
        let json: [String: Any] = [
            "type": "article",
            "body": "<img data-reference=\"image\" data-document-id=\"cms/api/amp/image/X1\" />\(p)\(p)",
            "imageResources": [["url": "https://img.msn.com/X1.img", "caption": "Tanner McKee throws.", "attribution": "Imagn", "cmsId": "cms/api/amp/image/X1"]],
        ]
        let out = try #require(MSNArticle.render(try JSONSerialization.data(withJSONObject: json), pageURL: "https://www.msn.com/en-us/a/ar-X"))
        let body = try #require(out.contentHtml)
        #expect(body.contains("src=\"https://img.msn.com/X1.img\""))
        #expect(body.contains("Tanner McKee throws. (Imagn)"))
        #expect(out.leadImage == "https://img.msn.com/X1.img")
    }

    @Test func npraudioLeadsTheContentAndItsModuleGoes() async throws {
        let audio = #"{"available":true,"duration":244,"audioUrl":"https:\/\/ondemand.npr.org\/a.mp3?t=progseg&e=1"}"#
        let html = """
        <html><head><title>Fishing</title></head><body><article><h1>Fishing</h1>
        <div id="headlineaudio"><article class="bucketwrap"><div class="audio-module"><h4>Fishing is a key issue</h4>
        <div data-audio='\(audio)'><a href="https://ondemand.npr.org/a.mp3">Listen · 4:04</a></div>
        <ul><li><a href="https://ondemand.npr.org/a.mp3">Download</a></li><li>Embed <code>&lt;iframe src="https://www.npr.org/player/embed/1"&gt;</code></li></ul>
        </div></article></div><div id="storytext">\(p)</div></article></body></html>
        """
        let body = try await extract(html)
        let found = try #require(SiteAudio.audio(in: body))
        #expect(found.url == "https://ondemand.npr.org/a.mp3?t=progseg&e=1")
        #expect(found.duration == 244)
        #expect(body.contains("The reader shows"))
        #expect(!body.contains("Download"))
        #expect(!body.contains("iframe"))
        #expect(SiteAudio.audio(in: "<p>No audio</p>") == nil)
    }

    @Test func lazyImagesKeepTheirSizesAndEmptySvgsGo() {
        let out = ArticleSanitizer.sanitize("""
        <img src="https://e.com/a.jpg" srcset="https://e.com/a-640.jpg 640w, https://e.com/a.jpg 1920w" sizes="auto, (max-width: 1920px) 100vw, 1920px">
        <p><svg viewBox="0 0 100 43"><use href="#logo"></use></svg></p>
        <svg viewBox="0 0 10 10"><rect width="10" height="10" fill="var(--color-chart-1)"></rect></svg>
        """)
        #expect(out.contains("sizes=\"(max-width: 1920px) 100vw, 1920px\""))
        #expect(!out.contains("43"))
        #expect(out.contains("fill=\"var(--color-chart-1, currentColor)\""))
    }

    @Test func captionsBesideTheirPicturesBecomeFigures() async throws {
        let html = """
        <html><head><title>Missiles</title></head><body><article><h1>Missiles</h1>
        <div class="imagewrap"><picture><img src="https://e.com/p.jpg" alt="x"></picture></div>
        <div class="credit-caption"><div class="caption"><p>Defense chiefs meet in Cebu. <b class="credit">EPA via AP</b>
        <b class="hide-caption"><b>hide caption</b></b></p></div><button>toggle caption</button>
        <span class="credit">EPA via AP</span></div>\(p)</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("<figcaption>"))
        #expect(body.components(separatedBy: "EPA via AP").count == 2)
        #expect(!body.contains("hide caption"))
        #expect(!body.contains("toggle caption"))
    }

    @Test func aCreditDrawnTwiceInAFigureShowsOnce() {
        let out = ArticlePasses.cleanArticle("""
        <figure><div><p><img src="https://e.com/c.png" width="1920" height="1080"></p><div><p>Credit: Google</p></div></div>
        <figcaption><span>Credit: Google</span></figcaption></figure><figure><div></div></figure>
        <p><a href="https://e.com/x"></a>\(Self.para)</p>
        """, base: nil)
        #expect(out.components(separatedBy: "Credit: Google").count == 2)
        #expect(out.components(separatedBy: "<figure>").count == 2)
        #expect(!out.contains("https://e.com/x"))
    }

    @Test func pageFurnitureLinesGo() {
        let out = ArticlePasses.cleanArticle("""
        <p>Oct. 29, 2026, 12:05 p.m. ET</p><p>Updated on: October 28, 2026 / 8:27 PM EDT / CBS News</p><p>By</p>
        <p>Advertisement</p>\(p)<p>— Sign up for OnSI's Free Buffalo Bills Newsletter —</p>
        <p><strong>MORE:</strong> <a href="https://e.com/more">Winners &amp; losers of the trade</a></p>
        <p><strong><a href="https://martech.e.com/redirect">Claim the best Kalshi promo code CBSSPORTS55, trade $25</a></strong>: Cardinals vs. Cowboys</p>
        <p>4 MIN READ</p><p>___</p><p>Edited by Paula Cohen</p><p>In:</p><ul><li><a href="/tag/health">Health</a></li><li><a href="/tag/cte">CTE</a></li></ul>
        """, base: "https://e.com/")
        #expect(out.contains("The reader shows"))
        for gone in ["2026", "By<", "Advertisement", "Newsletter", "MORE", "promo code", "MIN READ", "___", "Edited by", "Health"] {
            #expect(!out.contains(gone), "\(gone)")
        }
    }

    @Test func aCardWithAHeadingKeepsItsSmallLogo() async throws {
        let card = """
        <div class="freeform-content"><div><a href="https://e.com/jaguars"><img src="https://e.com/jaguars.png" width="60" height="60"></a>
        <div><h2><a href="https://e.com/jaguars">10. Jacksonville Jaguars</a></h2><p>Record: 4-2</p></div></div></div>
        """
        let body = try await extract("<html><head><title>Rankings</title></head><body><article><h1>Rankings</h1>\(p)\(card)\(p)</article></body></html>")
        #expect(body.contains("10. Jacksonville Jaguars"))
        #expect(body.contains("Record: 4-2"))
    }

    @Test func youTubePlayersTheirScriptNeverStartedAreRebuilt() async throws {
        let player = """
        <div class="yt-video-container"><iframe id="yt-A1y9njg1F6A" width="800" height="450"></iframe>
        <a href="" role="button" class="video"><img src="https://i.ytimg.com/vi/A1y9njg1F6A/hqdefault.jpg" alt=""></a></div>
        """
        let body = try await extract("<html><head><title>Clip</title></head><body><article><h1>Clip</h1>\(p)\(player)\(p)</article></body></html>")
        #expect(body.contains("youtube-nocookie.com/embed/A1y9njg1F6A"))
        #expect(!body.contains("hqdefault"))
    }

    @Test func authorCardsAndPopoversGo() async throws {
        let html = """
        <html><head><title>Rookies</title></head><body><article><h1>Rookies</h1>
        <div class="byline-wrap"><ul><li><div class="author-overlay"><a href="#">Close</a>Matt Bowen is a fantasy football analyst at ESPN.</div></li></ul></div>
        <div class="byline__author__popover" popover="hint">Kerry Breen is a news editor.</div>
        <a href="https://www.google.com/preferences/source?q=cbsnews.com">Add CBS News on Google</a>
        \(p)<p>is a news writer focused on creative industries, computing, and internet culture.</p></article></body></html>
        """
        let body = try await extract(html)
        #expect(!body.contains("Matt Bowen"))
        #expect(!body.contains("Kerry Breen"))
        #expect(!body.contains("Google"))
        #expect(!body.contains("news writer"))
    }

    @Test func aHeadingRepeatingTheTitleGoes() {
        let out = ArticleExtraction.dropTitleHeading("<h4>Fishing is a key issue in Alaska's tight US Senate race</h4>\(p)",
                                                     titles: ["Fishing is a key issue in Alaska's tight U.S. Senate race : NPR"])
        #expect(!out.contains("<h4>"))
        #expect(out.contains("The reader shows"))
    }

    @Test func boldOnlyParagraphsBecomeHeadings() {
        let out = ArticlePasses.cleanArticle("\(p)<p><b>Transaction details</b></p>\(p)<p><strong>VERDICT:</strong> A miss</p>", base: nil)
        #expect(out.contains("<h3>Transaction details</h3>"))
        #expect(out.contains("<strong>VERDICT:</strong> A miss"))
    }

    @Test func ghostMembersOnlyPostsAreWalled() {
        let page = "<article class=\"post\"><div class=\"post-sneak-peek\">\(p)</div><div class=\"post-access-cta\"><h2>This post is for paid members only</h2></div></article>"
        #expect(PaywallDetection.isWalled(pageHTML: page, articleHTML: p, url: "https://www.404media.co/x/"))
    }

    @Test func botChecksAreNotArticles() {
        #expect(ArticleExtraction.isLoginWall("<div><p>Please enable JS and disable any ad blocker</p></div>"))
        #expect(!ArticleExtraction.isLoginWall(p))
    }

    @Test func aVideoCardWithoutItsPlayerGoes() {
        let out = ArticlePasses.cleanArticle("""
        \(p)<figure><figcaption><a href="https://e.com/video/cte/"><span>Study estimates 75% had CTE</span> <span>03:01</span></a></figcaption></figure>
        <div><h4>Study estimates 75% had CTE</h4><p>(03:01)</p></div>
        """, base: nil)
        #expect(out.contains("The reader shows"))
        #expect(!out.contains("Study estimates"))
        #expect(!out.contains("03:01"))
    }

    @Test func chartsStyledByThePageGetDrawnInTheTextColor() {
        let out = ArticleSanitizer.sanitize("""
        <svg class="line-chart__svg" viewBox="0 0 100 50"><path d="M0,0L10,10"></path><text x="1" y="1">Q3</text></svg>
        <svg viewBox="0 0 10 10"><path d="M0,0L10,10"></path></svg>
        """)
        #expect(out.contains("fill=\"none\" stroke=\"currentColor\""))
        #expect(out.contains("<text x=\"1\" y=\"1\" fill=\"currentColor\">"))
        #expect(out.contains("<path d=\"M0,0L10,10\"></path></svg>"))
    }

    @Test func embeddedPostsAreDrawnAsPostsWithTheirVideo() async throws {
        let html = """
        \(p)<figure><blockquote><p>Granola now does voice typing. <a href="https://t.co/et60VtwWA0">pic.twitter.com/et60VtwWA0</a></p>
        — Granola (@meetgranola) <a href="https://x.com/meetgranola/status/2115837013975081208?ref_src=twsrc">October 29, 2026</a></blockquote></figure>
        <blockquote><p>A quote from a speech, linking <a href="https://e.com/speech">the speech</a>.</p></blockquote>
        """
        let json = """
        {"text":"Granola now does voice typing. https://t.co/et60VtwWA0","created_at":"2026-10-29T16:03:49.000Z",
         "favorite_count":816,"conversation_count":78,
         "user":{"name":"Granola","screen_name":"meetgranola","profile_image_url_https":"https://pbs.twimg.com/profile_images/1/a_normal.jpg"},
         "entities":{"media":[{"url":"https://t.co/et60VtwWA0"}]},
         "mediaDetails":[{"type":"video","media_url_https":"https://pbs.twimg.com/thumb.jpg","original_info":{"width":1920,"height":1080},
           "video_info":{"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/pl/a.m3u8"},
             {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/vid/avc1/1280x720/b.mp4"},
             {"content_type":"video/mp4","bitrate":10368000,"url":"https://video.twimg.com/vid/avc1/1920x1080/c.mp4"}]}}]}
        """
        let asked = LockedBox<[String]>([])
        let out = await EmbeddedPosts.expand(html) { url, _ in
            asked.set(asked.get() + [url])
            return (Data(json.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(asked.get() == ["https://cdn.syndication.twimg.com/tweet-result?id=2115837013975081208&lang=en&token=a"])
        #expect(out.contains("class=\"x-post x-embed\""))
        #expect(out.contains("src=\"https://video.twimg.com/vid/avc1/1280x720/b.mp4\""))
        #expect(out.contains("poster=\"https://pbs.twimg.com/thumb.jpg\""))
        #expect(out.contains("a_bigger.jpg"))
        #expect(out.contains("816 likes") && out.contains("78 replies"))
        #expect(out.contains("href=\"https://x.com/meetgranola/status/2115837013975081208\""))
        #expect(!out.contains("pic.twitter.com"))
        #expect(out.contains("A quote from a speech"))
        // An unreadable post keeps its blockquote.
        let kept = await EmbeddedPosts.expand(html) { _, _ in nil }
        #expect(kept == html)
    }

    @Test func everyNetworksEmbedBecomesABlockquoteEndingWithThePost() throws {
        let html = """
        <div><blockquote class="bluesky-embed" data-bluesky-uri="at://did:plc:abc/app.bsky.feed.post/3lxyz"><p>Hello from Bluesky</p>— Jay (@jay.bsky.social)</blockquote>
        <blockquote class="instagram-media" data-instgrm-permalink="https://www.instagram.com/p/DAbc123/"><div><svg></svg></div><a href="https://www.instagram.com/p/DAbc123/">View this post on Instagram</a></blockquote>
        <blockquote class="tiktok-embed" cite="https://www.tiktok.com/@nfl/video/7412345678901234567"><section><a href="https://www.tiktok.com/@nfl">@nfl</a> Touchdown!</section></blockquote>
        <blockquote class="text-post-media" data-text-post-permalink="https://www.threads.com/@mosseri/post/DAbc"><a href="https://www.threads.com/@mosseri/post/DAbc">View on Threads</a></blockquote>
        <iframe src="https://mastodon.social/@Gargron/113000000000000000/embed" class="mastodon-embed"></iframe>
        <iframe src="https://www.linkedin.com/embed/feed/update/urn:li:share:7300000000000000000"></iframe></div>
        """
        let doc = try #require(ExtractionDOM.parseDocument(html, baseURI: "https://e.com/"))
        ArticlePasses.normalizeEmbeds(doc)
        let posts = ExtractionDOM.select(doc, "blockquote").compactMap(EmbeddedPosts.post(of:))
        #expect(posts == [
            .social(url: "https://bsky.app/profile/did:plc:abc/post/3lxyz"),
            .social(url: "https://www.instagram.com/p/DAbc123/"),
            .tiktok(url: "https://www.tiktok.com/@nfl/video/7412345678901234567", id: "7412345678901234567"),
            .social(url: "https://www.threads.com/@mosseri/post/DAbc"),
            .social(url: "https://mastodon.social/@Gargron/113000000000000000"),
            .social(url: "https://www.linkedin.com/feed/update/urn:li:share:7300000000000000000"),
        ])
        #expect(ExtractionDOM.first(doc, "iframe") == nil)
    }

    @Test func aTikTokEmbedPlaysInTikToksPlayer() {
        let card = EmbeddedPosts.tiktokCard(["author_name": "NFL", "author_unique_id": "nfl", "title": "Touchdown!"],
                                            url: "https://www.tiktok.com/@nfl/video/7412345678901234567", id: "7412345678901234567")
        #expect(card.contains("<iframe src=\"https://www.tiktok.com/player/v1/7412345678901234567"))
        #expect(card.contains("Touchdown!"))
        #expect(card.contains("Open on TikTok"))
    }

    @Test func anotherNetworksPostGetsItsMarkAndLink() throws {
        let post = "<div class=\"x-post\"><div class=\"x-who\"><span class=\"x-name\">Jay</span></div><div class=\"x-body\"><p>Hi</p></div><div class=\"x-foot\"><span>Oct 29</span></div></div>"
        let out = try #require(EmbeddedPosts.decorated(post, network: "Bluesky", href: "https://bsky.app/profile/jay/post/1"))
        #expect(out.contains("class=\"x-post x-embed\""))
        #expect(out.contains("class=\"x-net\""))
        #expect(out.contains(">Open on Bluesky</a>"))
    }

    @Test func aLongQuotationCitingAPostIsLeftAlone() throws {
        let long = String(repeating: "A passage quoted at length from the speech. ", count: 40)
        let doc = try #require(ExtractionDOM.parseDocument("<blockquote><p>\(long)</p><a href=\"https://x.com/a/status/1\">source</a></blockquote>", baseURI: "https://e.com/"))
        #expect(ExtractionDOM.select(doc, "blockquote").compactMap(EmbeddedPosts.post(of:)).isEmpty)
    }

    @Test func aDatedLinkInsideTextStays() {
        let out = ArticlePasses.cleanArticle("<blockquote><p>\(Self.para)</p>— Granola (@meetgranola) <a href=\"https://x.com/a/status/1\">October 29, 2026</a></blockquote>", base: nil)
        #expect(out.contains("October 29, 2026"))
    }

    @Test func googleRedirectLinksGoStraightToTheirTarget() {
        #expect(ArticlePasses.unredirected("https://www.google.com/url?q=https://www.courtlistener.com/x&sa=D") == "https://www.courtlistener.com/x")
        #expect(ArticlePasses.unredirected("https://www.google.com/search?q=x") == "https://www.google.com/search?q=x")
    }
}
