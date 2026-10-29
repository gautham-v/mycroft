import Foundation
import Testing
@testable import OpenDispatchCore

/// Images and embeds the second audit found missing or broken: captioned pictures in lightbox buttons, players mounted
/// from page data (YouTube, ex.co, Mux, Cloudflare Stream), empty-iframe facades, posters, duplicate captions and videos,
/// Eater's Instagram posts, a podcast's audio, and the quoted post inside an X card.
@Suite("Extraction: media 2")
struct ExtractionMedia2Tests {
    static let para = "The reader shows the whole story, cleanly, without the page around it."
    func prose(_ n: Int) -> String { "<p>\(Self.para) Paragraph number \(n) has a few distinct words of its own, such as lantern\(n), harbor\(n) and thistle\(n), so no two look alike.</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func page(_ body: String, head: String = "") -> String {
        "<html><head><title>T</title>\(head)</head><body><article><h1>T</h1>\(prose(1))\(prose(2))\(body)\(prose(3))\(prose(4))</article></body></html>"
    }

    @Test func aCaptionedPictureInAnImageViewerButtonStays() async throws {
        let body = """
        <div data-testid="image-group"><button type="button" aria-label="Open image viewer" aria-haspopup="dialog"><div class="ImageEmbed"><div class="container"><figure>
        <img alt="King welcomed" src="https://i2.example.com/a.jpg"><div data-testid="image-count-label"><div data-testid="label"><svg viewBox="0 0 8 8"><path d="M0 0"/></svg><span>View 3 Images</span></div></div></figure></div>
        <figcaption><p>King welcomed by the President (Image: Aaron Chown)</p></figcaption></div></button></div>
        """
        let out = try await extract(page(body))
        #expect(out.contains("https://i2.example.com/a.jpg"))
        #expect(out.contains("King welcomed by the President"))
        #expect(!out.contains("View 3 Images"))
        #expect(!out.contains("<button"))
    }

    @Test func consentAndBlockerNoticesGo() async throws {
        let body = """
        <figure><svg viewBox="0 0 8 8"><path d="M0 0"/></svg><figcaption>Content cannot be displayed without consent</figcaption></figure>
        <div><p>To display this content from YouTube, you must enable advertisement tracking and audience measurement.</p></div>
        <div><p>One of your browser extensions seems to be blocking the video player from loading. To watch this content, you may need to disable it on this site.</p></div>
        <img src="https://cdn.jwplayer.com/v2/media/yJ29FRt3/poster.jpg"><p>Play Video</p>
        """
        let out = try await extract(page(body))
        #expect(!out.contains("without consent"))
        #expect(!out.contains("advertisement tracking"))
        #expect(!out.contains("browser extensions"))
        #expect(!out.contains("Play Video"))
        #expect(out.contains("poster.jpg"))
    }

    @Test func aFacadeWithAnEmptyFrameBecomesTheYouTubePlayer() async throws {
        let body = """
        <figure class="video"><div class="embedly-plugin" data-type="video"><div class="video-image"><div class="youtube-video-title">Gulliver at 300: Introduction</div>
        <div class="watch-on-youtube"><a href="https://www.youtube.com/watch?v=U1cGcGpHoEA">Watch on <img src="/static/yt.png" alt="YouTube Logo"></a></div>
        <div class="video-thumbnail"><img src="https://i.ytimg.com/vi/U1cGcGpHoEA/maxresdefault.jpg" data-video-id="U1cGcGpHoEA" alt="Gulliver at 300: Introduction"></div></div>
        <iframe width="854" src="" frameborder="0" id="player" allowfullscreen title="Gulliver at 300: Introduction"></iframe></div></figure>
        """
        let out = try await extract(page(body))
        #expect(out.contains("<iframe src=\"https://www.youtube-nocookie.com/embed/U1cGcGpHoEA\""))
        #expect(!out.contains("maxresdefault"))
        #expect(!out.contains("Watch on"))
    }

    @Test func youTubePlaceholdersTakeTheClipsFromThePageData() async throws {
        let slot = "<div class=\"wp-block-youtube-embed\" data-module=\"youtube-embed\" data-sentry-component=\"YoutubeEmbed\"><button data-action=\"play-youtube\"><svg viewBox=\"0 0 8 8\"><path d=\"M0 0\"/></svg></button></div>"
        let data = #"""
        {"blocks":[{"__typename":"RingerBlocksYoutubeEmbed","id":"a1","parentId":null,"attributes":{"embedTitle":"","link":"https://www.youtube.com/watch?v=vvTlMYS85RA","__typename":"X"}},
        {"__typename":"CoreParagraph","id":"p"},{"__typename":"RingerBlocksYoutubeEmbed","id":"a2","parentId":null,"attributes":{"embedTitle":"","link":"https://youtu.be/2TSpfRISYyo"}}]}
        """#
        let head = "<script id=\"__NEXT_DATA__\" type=\"application/json\">\(data)</script>"
        let out = try await extract(page("\(slot)\(prose(5))\(slot)", head: head))
        let first = try #require(out.range(of: "vvTlMYS85RA"))
        let second = try #require(out.range(of: "2TSpfRISYyo"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(out.components(separatedBy: "<iframe").count == 3)
        // Counts that disagree are not guessed at.
        let uneven = try await extract(page(slot + slot + slot, head: head))
        #expect(!uneven.contains("<iframe"))
    }

    @Test func eaterMapEntriesGetTheirInstagramPosts() async throws {
        let embed = #"<blockquote class=\"instagram-media\" data-instgrm-permalink=\"https://www.instagram.com/p/DPWn4A9immQ/?utm_source=ig_embed&utm_campaign=loading\"></blockquote>"#
        let data = #"{"props":{"mapPoints":[{"name":"Ultramarinos Marin","ledeMedia":{"provider":"instagram","embedHtml":"\#(embed)"}},{"name":"Brabo","ledeMedia":null}]}}"#
        let card = { (slug: String, name: String) in
            "<div data-slug=\"\(slug)\"><div><h2>\(name)</h2><span><button type=\"button\" aria-label=\"Save to a list\">+</button></span></div>\(self.prose(slug.count))</div>"
        }
        let body = card("ultramarinos-marin", "Ultramarinos Marin") + card("brabo", "Brabo")
        let out = try await extract(page(body, head: "<script id=\"__NEXT_DATA__\" type=\"application/json\">\(data)</script>"))
        #expect(out.contains("href=\"https://www.instagram.com/p/DPWn4A9immQ/\""))
        #expect(out.components(separatedBy: "instagram.com/p/").count == 2)
        let post = ExtractionDOM.withFragment(out) { body in ExtractionDOM.first(body, "blockquote").flatMap(EmbeddedPosts.post(of:)) }
        #expect(post == .some(.social(url: "https://www.instagram.com/p/DPWn4A9immQ/")))
    }

    @Test func anExCoPushBecomesTheVideo() async throws {
        let body = """
        <script>window.videoEmbeds = window.videoEmbeds || [];
        window.videoEmbeds.push({
            elemId: 'video-container-01sn',
            data: {"slug":"01sn","url":"https:\\/\\/cdn.ex.co\\/transformations\\/production\\/aa60\\/master.m3u8","title":"Readers' Choice: How Surveys Help","thumbnail_url":"https:\\/\\/cdn.ex.co\\/transformations\\/production\\/aa60\\/thumbnail-720.webp","duration":102},
            variation: 'EMBED'
        });</script>
        <div class="video-parent"><div id="video-container-01sn" class="!h-full"><div><svg viewBox="0 0 8 8"><path d="M0 0"/></svg></div></div></div>
        """
        let out = try await extract(page(body))
        #expect(out.contains("<video src=\"https://cdn.ex.co/transformations/production/aa60/master.m3u8\""))
        #expect(out.contains("poster=\"https://cdn.ex.co/transformations/production/aa60/thumbnail-720.webp\""))
        #expect(out.contains("<figcaption>Readers' Choice: How Surveys Help"))
    }

    @Test func aMuxPlayerBoxBecomesTheStream() async throws {
        let body = """
        <figure><div style="overflow:hidden;width:fit-content"><div class="media-border-container media-controller" style="aspect-ratio:16/9;background-image:url(https://image.mux.com/wSa1Fv0202Op/thumbnail.jpg?time=0);background-size:cover"></div></div></figure>
        <div style="aspect-ratio:1920 / 1080"><div class="media-border-container w-full" style="background-image:url(https://image.mux.com/oU5xjcW00M/thumbnail.jpg?time=0)"></div></div>
        """
        let out = try await extract(page(body))
        #expect(out.contains("<video src=\"https://stream.mux.com/wSa1Fv0202Op.m3u8\""))
        #expect(out.contains("poster=\"https://image.mux.com/wSa1Fv0202Op/thumbnail.jpg\""))
        #expect(!out.contains("oU5xjcW00M"))
    }

    @Test func aCloudflareStreamFrameBecomesTheVideoWithoutItsPosterPicture() async throws {
        let id = "a1e654aee5706f82440ee2d7d4f90295"
        let body = """
        <figure><div><img src="/video-posters/\(id)-1280.webp" alt="" aria-hidden="true"><iframe src="https://iframe.videodelivery.net/\(id)?controls=true&amp;poster=https%3A%2F%2Fe.com%2Fvideo-posters%2F\(id)-1280.webp" title="Reading the Code"></iframe></div></figure>
        """
        let out = try await extract(page(body))
        #expect(out.contains("<video src=\"https://videodelivery.net/\(id)/manifest/video.m3u8\""))
        #expect(out.contains("poster=\"https://e.com/video-posters/\(id)-1280.webp\""))
        #expect(!out.contains("<iframe"))
        #expect(!out.contains("<img"))
    }

    @Test func aPlaceholderPosterTakesTheLazyOne() async throws {
        let body = """
        <div class="vjs-wrapper"><h2>No clear winner</h2><video controls preload="none" poster="data:image/png;base64,iVBORw0KGgo=" data-posterurl="https://static.dw.com/image/79791332_605.webp"><source src="https://tvdownloaddw-a.akamaihd.net/a.mp4" type="video/mp4"></video></div>
        """
        let out = try await extract(page(body))
        #expect(out.contains("poster=\"https://static.dw.com/image/79791332_605.webp\""))
    }

    @Test func theSameVideoShownTwiceStaysOnceWithItsHeading() async throws {
        let video = "<video controls><source src=\"https://dw.example/v1.mp4\" type=\"video/mp4\"></video>"
        let body = "<div><h2>Are the EU and Canada moving closer?</h2>\(video)</div>\(prose(5))\(prose(6))<div><h2>Are the EU and Canada moving closer?</h2>\(video)</div>"
        let out = try await extract(page(body))
        #expect(out.components(separatedBy: "<video").count == 2)
        #expect(out.components(separatedBy: "moving closer").count == 2)
    }

    @Test func aStillBesideItsVideoGoes() async throws {
        let poster = "https://q.example/still.jpg"
        let body = "<figure><div><p><video src=\"https://q.example/v.mp4\" poster=\"\(poster)\" controls></video></p><p><img src=\"\(poster)\" loading=\"lazy\"></p></div><figcaption>A time-lapse of a spider spinning its web.</figcaption></figure>"
        let out = try await extract(page(body))
        #expect(out.components(separatedBy: "still.jpg").count == 2)
        #expect(out.contains("<video"))
    }

    @Test func aCaptionTwinPerLayoutIsMergedIntoOne() async throws {
        let body = """
        <figure><img src="https://q.example/a.jpg" alt="widow"><figcaption class="m:hidden"><div class="caption"><p>To catch prey, black widows (top) lay a mess of sticky strands that acts as a trip wire (bottom).</p></div></figcaption>
        <figcaption><div class="caption s:hidden"><p>To catch prey, black widows (left) lay a mess of sticky strands that acts as a trip wire (right).</p></div><div class="attribution"><p>Phil Degginger/Alamy</p></div></figcaption></figure>
        """
        let out = try await extract(page(body))
        #expect(out.contains("(top)"))
        #expect(!out.contains("(left)"))
        #expect(out.contains("Phil Degginger/Alamy"))
        #expect(out.components(separatedBy: "<figcaption").count == 2)
    }

    @Test func aPictureWithNoAddressIsDropped() async throws {
        let body = "<div><img width=\"100\" height=\"100\" id=\"overlay\" src=\"data:image/png;base64,iVBORw0KGgo=\"></div><p>\(Self.para) Between pictures.</p><img src=\"https://e.com/real.jpg\" alt=\"Real\">"
        let out = try await extract(page(body))
        #expect(!out.contains("data:image"))
        #expect(!out.contains("<img width=\"100\""))
        #expect(out.contains("real.jpg"))
    }

    @Test func aRelatedCardsVideoFacadeIsNotThePlayerForTheStory() async throws {
        let body = """
        <div class="post-card"><div class="tease-thumbnail"><img src="https://g.example/t.png"><button class="js-facade" aria-label="Play video">Play</button>
        <template><iframe src="https://www.youtube.com/embed/EQeJj0hoPS8?feature=oembed&amp;autoplay=1"></iframe></template></div></div>
        """
        let out = try await extract(page(body))
        #expect(!out.contains("EQeJj0hoPS8"))
    }

    @Test func aPlayersTitleLineBecomesTheClipFromTheJSONLD() async throws {
        let ld = #"{"@type":"NewsArticle","video":[{"@type":"VideoObject","name":"Putin asked if Russia could target British military facilities","contentUrl":"https://v.example/x.m3u8","thumbnailUrl":"https://v.example/x.jpg"}]}"#
        let head = "<script type=\"application/ld+json\">\(ld)</script>"
        let body = "<div><p><span>Putin asked if Russia could target British military facilities</span></p></div>"
        let out = try await extract(page(body, head: head))
        #expect(out.contains("<video src=\"https://v.example/x.m3u8\""))
        #expect(out.contains("poster=\"https://v.example/x.jpg\""))
        #expect(!out.contains("Putin asked"))
        // The same words inside a paragraph of the story are prose.
        let prose = try await extract(page("<p>\(Self.para) Putin asked if Russia could target British military facilities, and replied.</p>", head: head))
        #expect(!prose.contains("<video"))
    }

    @Test func aYouTubeThumbnailWithAPlayButtonBecomesThePlayer() async throws {
        let body = """
        <div><img src="https://img.youtube.com/vi/dJ-SIBF1nJQ/hqdefault.jpg" alt="" width="480" height="360"><button type="button" aria-label="Play video"><span><svg viewBox="0 0 8 8"><path d="M0 0"/></svg></span></button></div>
        <p><img src="https://img.youtube.com/vi/AAAAAAAAAAA/hqdefault.jpg" alt="A screenshot of a video"></p>
        """
        let out = try await extract(page(body))
        #expect(out.contains("https://www.youtube-nocookie.com/embed/dJ-SIBF1nJQ"))
        #expect(!out.contains("hqdefault.jpg\" alt=\"\""))
        // No play button: it is a picture.
        #expect(out.contains("AAAAAAAAAAA/hqdefault.jpg"))
        #expect(!out.contains("embed/AAAAAAAAAAA"))
    }

    @Test func aClipInANoscriptIsKept() async throws {
        let body = "<div><noscript><video autoplay loop muted src=\"https://assets.vogue.example/clips/a.mp4\"></video></noscript></div>"
        let out = try await extract(page(body))
        #expect(out.contains("<video"))
        #expect(out.contains("https://assets.vogue.example/clips/a.mp4"))
    }

    @Test func theMirrorsCropLettersAreNotPartOfAnImagesName() {
        let body = "<p><img src=\"https://i2-prod.mirror.co.uk/article37824683.ece/ALTERNATES/s1200f/0_GUYANA-BRITAIN-ROYALS.jpg\" width=\"1200\"></p>"
        #expect(LeadImage.contentHasHero(body, hero: "https://i2-prod.mirror.co.uk/article37824683.ece/ALTERNATES/s1200d/0_GUYANA-BRITAIN-ROYALS.jpg"))
        #expect(!LeadImage.contentHasHero(body, hero: "https://i2-prod.mirror.co.uk/article37824999.ece/ALTERNATES/s1200d/0_OTHER-PICTURE.jpg"))
    }

    @Test func aPodcastAudioElementLeadsTheContent() async throws {
        let body = "<aside class=\"post__aside\"><div class=\"podcast\"><audio preload=\"none\" data-role=\"podcast\"><source src=\"https://dts.podtrac.com/redirect.mp3/ep.mp3\" type=\"audio/mpeg\">No audio.</audio></div></aside>"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: page(body), pageURL: "https://e.com/story")
        let content = try #require(out.contentHtml)
        #expect(SiteAudio.audio(in: content)?.url == "https://dts.podtrac.com/redirect.mp3/ep.mp3")
        #expect(content.contains("lantern1"))
    }

    // MARK: X cards

    func syndication(text: String, quoted: String) -> Data {
        Data(#"""
        {"text":"\#(text)","user":{"name":"BioTender","screen_name":"Junioryu","profile_image_url_https":"https://pbs.twimg.com/p_normal.jpg"},"created_at":"2026-10-17T06:57:56.000Z","favorite_count":3,
        "quoted_tweet":{"id_str":"2111350983465095501","text":"\#(quoted)","created_at":"2026-10-17T06:00:00.000Z","user":{"name":"Anthropic","screen_name":"AnthropicAI","profile_image_url_https":"https://pbs.twimg.com/a_normal.jpg"},"entities":{"urls":[]}}}
        """#.utf8)
    }

    @Test func anXCardDecodesTheTextsEntitiesOnceAndShowsTheQuotedPost() throws {
        let data = syndication(text: "&gt;10\\u00d7 tighter &amp; faster\\n\\nSecond line", quoted: "Over the past few months &amp; weeks, we have worked with partners")
        let card = try #require(EmbeddedPosts.card(from: data, canonical: "https://x.com/Junioryu/status/1"))
        #expect(card.contains("&gt;10\u{00d7} tighter &amp; faster"))
        #expect(!card.contains("&amp;gt;"))
        #expect(!card.contains("&amp;amp;"))
        #expect(card.contains("<div class=\"x-quote\">"))
        #expect(card.contains("Anthropic"))
        #expect(card.contains("Over the past few months &amp; weeks"))
        #expect(card.contains("href=\"https://x.com/AnthropicAI/status/2111350983465095501\""))
    }

    @Test func anXCardWithoutAQuotedPostHasNoQuoteBlock() throws {
        let data = Data(#"{"text":"Hello","user":{"name":"A","screen_name":"a"},"created_at":"2026-10-17T06:57:56.000Z"}"#.utf8)
        let card = try #require(EmbeddedPosts.card(from: data, canonical: "https://x.com/a/status/1"))
        #expect(!card.contains("x-quote"))
    }

    @Test func mlbPortraitClipsAskForAPortraitPoster() async throws {
        let video = { (name: String, poster: String) in
            "<figure><video src=\"https://mlb-cuts.example/\(name)\" poster=\"https://img.mlbstatic.com/mlb-images/image/upload/\(poster)/mlb/x.jpg\" controls></video><figcaption>Clip \(name)</figcaption></figure>"
        }
        let body = video("a_1280x720_59_4000K.mp4", "c_fill,w_1280,h_720,f_jpg,q_auto") + video("b_720x1280_59_4000K_portrait.mp4", "c_fill,w_1280,h_720,f_jpg,q_auto")
        let out = try await extract(page(body))
        #expect(out.contains("c_fill,w_1280,h_720"))
        #expect(out.contains("c_fill,w_720,h_1280"))
    }
}

@Suite("Extraction: media 2 in WebKit", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionMedia2WebKitTests {
    static let para = ExtractionMedia2Tests.para
    func prose(_ n: Int) -> String { "<p>\(Self.para) Paragraph number \(n) has a few distinct words of its own, such as lantern\(n), harbor\(n) and thistle\(n), so no two look alike.</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    @Test @MainActor func aCaptionedPictureInAnImageViewerButtonSurvivesReadability() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>\(prose(1))\(prose(2))
        <div data-testid="image-group"><button type="button" class="SlideViewerButton" aria-label="Open image viewer" aria-haspopup="dialog" aria-controls="image-lightbox"><div class="ImageEmbed_image-embed__0T8WX"><div class="ImageEmbed_image-container__2AIQm"><figure class="Figure_figure__Uce4f" style="--figure-aspect-ratio:1.5">
        <img alt="King welcomed" loading="lazy" src="https://i2.example.com/a.jpg" srcSet="https://i2.example.com/a-458.jpg 458w, https://i2.example.com/a.jpg 1200w"><div class="ImageCountLabel_view-images-label__pxKau" data-testid="image-count-label"><div data-testid="label" class="Tag_label__s0LCV"><span>View 3 Images</span></div></div></figure></div>
        <figcaption class="ImageCaption_caption__j7HRu"><p class="ImageCaption_caption-title__ccyQU">King welcomed by the President<cite>(Image: Aaron Chown)</cite></p></figcaption></div></button></div>
        \(prose(3))\(prose(4))</article></body></html>
        """
        let out = try await extract(html)
        #expect(out.contains("i2.example.com/a.jpg"))
        #expect(out.contains("King welcomed by the President"))
        #expect(!out.contains("View 3 Images"))
    }

    @Test @MainActor func twoSideBySidePhotosWithOneCaptionSurviveReadability() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>\(prose(1))\(prose(2))
        <div class="artSplitter mol-img-group"><div class="splitLeft"><div class="mol-img"><div class="image-wrap"><img src="https://i.dailymail.com/a-m-61.jpg" height="633" width="306" alt="Jackie Apostel" class="blkBorder img-share" loading="lazy"></div></div></div>
        <div class="splitRight"><div class="mol-img"><div class="image-wrap"><img src="https://i.dailymail.com/b-a-62.jpg" height="633" width="306" alt="Kim Turnbull" class="blkBorder img-share" loading="lazy"></div></div></div>
        <div class="clear"></div><p class="imageCaption">Jackie Apostel (L) and Kim Turnbull (R) enjoyed a girls night out</p></div>
        \(prose(3))\(prose(4))</article></body></html>
        """
        let out = try await extract(html)
        #expect(out.contains("a-m-61.jpg"))
        #expect(out.contains("b-a-62.jpg"))
        #expect(out.contains("enjoyed a girls night out"))
    }

    @Test @MainActor func aDatawrapperFrameInAShareNamedBoxSurvivesReadability() async throws {
        let html = """
        <html><head><title>T</title></head><body><article><h1>T</h1>\(prose(1))\(prose(2))
        <div id="share-id-2VMPn" class="data-wrapper-embed" data-datawrapper-id="2VMPn"><style>.dw-dark { display: none; }</style>
        <div id="inline-graphic"><iframe id="datawrapper-chart-2VMPn" class="dw-dark" style="width:100%;height:100%" src="https://datawrapper.dwcdn.net/2VMPn/1/?dark=true" frameborder="0" scrolling="no"></iframe></div>
        <p><iframe id="datawrapper-chart-2VMPn" class="dw-light" style="width:100%;height:100%" src="https://datawrapper.dwcdn.net/2VMPn/1/?dark=false" frameborder="0" scrolling="no"></iframe> <script>window.addEventListener("message", function(){});</script></p></div>
        \(prose(3))\(prose(4))</article></body></html>
        """
        let out = try await extract(html)
        #expect(out.contains("datawrapper.dwcdn.net/2VMPn/1/?dark=false"))
        #expect(!out.contains("dark=true"))
    }
}
