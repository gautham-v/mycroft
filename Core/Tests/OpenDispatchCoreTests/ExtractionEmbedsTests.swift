import Foundation
import Testing
@testable import OpenDispatchCore

/// Embeds the audit of 130 sources found dropped or drawn badly: Datawrapper and Flourish charts, CNBC's wildcard charts
/// and videos, Vice's click-to-play YouTube, Substack's tweet and post cards, MLB's clips, srcdoc chart documents.
@Suite("Extraction: embeds")
struct ExtractionEmbedsTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func page(_ body: String, head: String = "") -> String {
        "<html><head><title>T</title>\(head)</head><body><article><h1>T</h1>\(p)\(body)\(p)</article></body></html>"
    }

    @Test func datawrapperScriptBecomesItsChartFrame() async throws {
        let body = """
        <div class="insider-raw-embed" data-script="https://datawrapper.dwcdn.net/e9ORK/embed.js"><div class="vendor-datawrapper" data-id="e9ORK">
        <script>window.allScripts = [];</script>
        <div style="min-height:423px" id="datawrapper-vis-e9ORK"></div><script src="https://datawrapper.dwcdn.net/e9ORK/embed.js" data-target="#datawrapper-vis-e9ORK"></script>
        <noscript><img src="https://datawrapper.dwcdn.net/e9ORK/full.png" alt="Line chart"></noscript></div></div>
        """
        let out = try await extract(page(body))
        #expect(out.contains("<iframe src=\"https://datawrapper.dwcdn.net/e9ORK/\" height=\"423\">"))
        #expect(!out.contains("full.png"))
        #expect(!out.contains("<script"))
    }

    @Test func flourishFrameKeepsItsHeightOrGetsOne() async throws {
        let out = try await extract(page("""
        <div><iframe src="https://flo.uri.sh/visualisation/30736264/embed?auto=1" frameborder="0" scrolling="no" height="575" width="700" style="width:100%;" title="Interactive"></iframe></div>
        <iframe src="https://public.flourish.studio/visualisation/1/embed" height="100%"></iframe>
        """))
        #expect(out.contains("src=\"https://flo.uri.sh/visualisation/30736264/embed?auto=1\""))
        #expect(out.contains("height=\"575\""))
        #expect(out.contains("height=\"\(ArticlePasses.defaultChartHeight)\""))
    }

    @Test func otherHostsStayOutOfTheAllowlist() {
        let html = "<iframe src=\"https://evil.example/x\"></iframe><iframe src=\"https://datawrapper.dwcdn.net/abc/\" height=\"300\"></iframe>"
        let out = ArticleSanitizer.sanitize(html)
        #expect(!out.contains("evil.example"))
        #expect(out.contains("datawrapper.dwcdn.net/abc/"))
    }

    @Test func clickToPlayYouTubeInATemplateBecomesThePlayer() async throws {
        let body = """
        <h2>Song</h2>
        <div class="wp-block-savage-platform-youtube-placeholder"><button type="button"><span class="screen-reader-text">Play video</span>
        <picture><img src="https://img.youtube.com/vi/XEA6-RlhSb4/hqdefault.jpg" alt="Play"></picture></button>
        <template><figure class="wp-block-embed"><div><iframe width="500" height="375" src="https://www.youtube.com/embed/XEA6-RlhSb4?feature=oembed&amp;autoplay=1" allowfullscreen></iframe></div></figure></template>
        <noscript><figure><iframe src="https://www.youtube.com/embed/XEA6-RlhSb4?feature=oembed"></iframe></figure></noscript></div>
        """
        let out = try await extract(page(body))
        #expect(out.components(separatedBy: "<iframe").count == 2)
        #expect(out.contains("https://www.youtube-nocookie.com/embed/XEA6-RlhSb4?feature=oembed"))
        #expect(!out.contains("autoplay"))
        #expect(!out.contains("hqdefault"))
        #expect(!out.contains("width=\"500\""))
    }

    @Test func substackTweetBecomesABlockquoteEmbeddedPostsDraws() async throws {
        let attrs = #"{"url":"https://x.com/drorpoleg/status/2111882070376980529","full_text":"Progress is accelerating &amp;gt; 2x.\n\nSee below.","username":"drorpoleg","name":"Dror Poleg","date":"2026-10-18T18:08:17.000Z","photos":[],"quoted_tweet":{"full_text":"x"}}"#
        let body = "<div class=\"pencraft tweet twitter-embed\" data-attrs='\(attrs)'><div><p>Dror Poleg</p><a href=\"https://x.com/drorpoleg/status/2111882070376980529\"><img src=\"https://pbs.substack.com/a_normal.jpg\"></a></div></div>"
        let out = try await extract(page(body))
        #expect(out.contains("<blockquote>"))
        #expect(out.contains("Progress is accelerating &gt; 2x."))
        #expect(out.contains("Dror Poleg (@drorpoleg)"))
        #expect(!out.contains("a_normal.jpg"))
        let post = ExtractionDOM.withFragment(out) { body in ExtractionDOM.first(body, "blockquote").flatMap(EmbeddedPosts.post(of:)) }
        #expect(post == .some(.x(user: "drorpoleg", id: "2111882070376980529")))
    }

    @Test func substackPostEmbedIsALinkCard() async throws {
        let attrs = #"{"url":"https://www.cremieux.xyz/p/yes-and-urbanism","publication_name":"Cremieux Recueil","publication_logo_url":"https://substackcdn.com/logo.png","title":"\"Yes, and...\" Urbanism"}"#
        let body = "<p>Cremieux had a good post:</p><div class=\"embedded-post-wrap\" data-attrs='\(attrs)'><a class=\"embedded-post\" href=\"https://www.cremieux.xyz/p/yes-and-urbanism?utm=1\"><div class=\"embedded-post-title\">\"Yes, and...\" Urbanism</div></a></div>"
        let out = try await extract(page(body))
        #expect(out.contains("<a class=\"x-card\" href=\"https://www.cremieux.xyz/p/yes-and-urbanism\""))
        #expect(out.contains("Cremieux Recueil"))
        #expect(out.contains("&quot;Yes, and...&quot; Urbanism") || out.contains("\"Yes, and...\" Urbanism"))
    }

    @Test func srcdocDocumentsAreNotKept() async throws {
        let out = try await extract(page("""
        <figure><iframe title="LFM3 Family" sandbox="allow-scripts" srcdoc="&lt;!doctype html&gt;&lt;script&gt;alert(1)&lt;/script&gt;" style="height:480px"></iframe></figure>
        """))
        #expect(!out.contains("srcdoc"))
        #expect(!out.contains("alert"))
        #expect(out.contains("Interactive figure \u{201C}LFM3 Family\u{201D} not shown here"))
        #expect(out.contains("href=\"https://e.com/story\""))
    }

    static let cnbcState = #"""
    window.__s_data={"page":{"content":[
      {"tagName":"div","data":{"__typename":"asset"},"children":[{"tagName":"p","children":["Earnings roll out from ExxonMobil, Chevron and ConocoPhillips this week."]}]},
      {"tagName":"wildcard","data":{"__typename":"wildcard","wildcard":{"wildcardPromo":{"cdata":"<iframe title=\"Big Energy Earnings\" id=\"datawrapper-chart-H3xlo\" src=\"https://datawrapper.dwcdn.net/H3xlo/1/\" scrolling=\"no\" height=\"280\"></iframe><script>(function(){})()<\u002Fscript>"}}},"children":[]},
      {"tagName":"div","data":{"__typename":"asset"},"children":[{"tagName":"p","children":["I'll just be blunt: these numbers are going to be big."]}]},
      {"tagName":"cnbcvideo","attributes":{"vcpsId":7000428871,"title":"Interview with the Secretary","url":"https://www.cnbc.com/video/2026/10/27/interview.html"},"data":{"encodings":[
        {"url":"https://x.net/master.m3u8","formatName":"mpeg4_1_HLSMBRStreaming"},
        {"url":"https://x.net/hd_MBR_4500.mp4","formatName":"mpeg4_4500000_Download"},
        {"url":"https://x.net/hd_H264_1M_720x405.mp4","formatName":"mpeg4_1100000_Download"},
        {"url":"https://x.net/hd_L.mp4","formatName":"mpeg4_500000_Download"}]}}
    ]}};
    """#

    @Test func cnbcChartsAndVideosAreFilledFromThePageData() async throws {
        let body = """
        <div class="group"><p>Earnings roll out from ExxonMobil, Chevron and ConocoPhillips this week.</p></div>
        <div style="height:400px" class="lazyload-placeholder"></div>
        <div class="group"><p>I'll just be blunt: these numbers are going to be <em>big</em>.</p></div>
        <div role="region"><div role="button" class="PlaceHolder-wrapper" data-vilynx-id="7000428871"><div class="InlineVideo-wrapper">
        <img src="https://image.cnbcfm.com/api/v1/image/1.jpg?w=750&amp;h=422" alt="Interview"><span class="PlayButton-flyout">watch now</span>
        <div class="InlineVideo-title">Interview with the Secretary</div></div></div></div>
        """
        let out = try await extract(page(body, head: "<script>\(Self.cnbcState)</script>"))
        #expect(out.contains("src=\"https://datawrapper.dwcdn.net/H3xlo/1/\""))
        #expect(out.contains("height=\"280\""))
        #expect(out.range(of: "ExxonMobil")!.lowerBound < out.range(of: "datawrapper.dwcdn.net")!.lowerBound)
        #expect(out.range(of: "datawrapper.dwcdn.net")!.lowerBound < out.range(of: "I'll just be blunt")!.lowerBound)
        #expect(out.contains("<video src=\"https://x.net/hd_H264_1M_720x405.mp4\""))
        #expect(out.contains("poster=\"https://image.cnbcfm.com/api/v1/image/1.jpg?w=750&amp;h=422\""))
        #expect(!out.contains("watch now"))
        #expect(out.contains("Interview with the Secretary"))
    }

    @Test func mlbClipsPlayFromTheirMp4() async throws {
        let data = #"""
        {"parts":[{"__typename":"Video","preferredPlaybackScenarioURL({\"preferredPlaybacks\":\"mp4AvcPlayback\"})":"https://mlb-cuts-diamond.mlb.com/FORGE/a_1280x720_59_4000K.mp4","type":"video","slug":"william-contreras-on-2026-wins","thumbnail":{"__typename":"Thumbnail","templateUrl":"https://img.mlbstatic.com/mlb-images/image/upload/{formatInstructions}/mlb/nsw6"},"title":"William Contreras on 2026 wins: 'Very blessed year'","relativeSiteUrl":"/video/william-contreras-on-2026-wins"},
        {"__typename":"Video","preferredPlaybackScenarioURL({\"preferredPlaybacks\":\"mp4AvcPlayback\"})":"https://mlb-cuts-diamond.mlb.com/FORGE/b_1280x720_59_4000K.mp4","type":"video","slug":"other-clip","title":"Other","relativeSiteUrl":"/video/other-clip"}]}
        """#
        let body = """
        <div class="story-part video"><div id="media-william-contreras-on-2026-wins-wrapper"></div></div>
        <div class="story-part video"><div id="media-unknown-clip-wrapper"></div></div>
        """
        let out = try await extract(page(body, head: "<script>window.__APOLLO__=\(data);</script>"))
        #expect(out.contains("<video src=\"https://mlb-cuts-diamond.mlb.com/FORGE/a_1280x720_59_4000K.mp4\""))
        #expect(out.contains("poster=\"https://img.mlbstatic.com/mlb-images/image/upload/c_fill,w_1280,h_720,f_jpg,q_auto/mlb/nsw6.jpg\""))
        #expect(out.contains("William Contreras on 2026 wins: 'Very blessed year'"))
        #expect(!out.contains("b_1280x720"))
    }
}
