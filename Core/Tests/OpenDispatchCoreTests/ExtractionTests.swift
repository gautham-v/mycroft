import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Readability stand-in: returns the <article> (or <body>) contents of the prepared document, so the passes around
/// Readability can be tested without WebKit.
struct FakeReadability: ReadabilityEngine {
    var calls: @Sendable (String) -> Void = { _ in }
    func articleContent(html: String, baseURL: String) async throws -> String? {
        calls(html)
        guard let doc = try? SwiftSoup.parse(html, baseURL) else { return nil }
        let el = try? doc.select("article").first() ?? doc.body()
        return try el?.html()
    }
}

private enum ExtractFixture {
    static let para = String(repeating: "OpenDispatch reads the whole article so the reader never needs the site. ", count: 4)

    /// SwiftSoup parents are weak references: keep every fixture document alive for the test run.
    nonisolated(unsafe) private static var retained: [Document] = []
    private static let retainLock = NSLock()

    static func root(_ html: String) throws -> Element {
        let doc = try #require(ExtractionDOM.parseDocument("<div id=\"r\">\(html)</div>"))
        retainLock.lock()
        retained.append(doc)
        retainLock.unlock()
        return try #require(ExtractionDOM.first(doc, "#r"))
    }

    static func html(_ el: Element) -> String { ExtractionDOM.innerHTML(el) }
}

@Suite("Extraction: srcset and URLs")
struct ExtractionURLTests {
    @Test func srcsetWithCommasInURLs() {
        let c = ArticlePasses.parseSrcset("https://cdn.x/w_640,c_fill/a.jpg 640w, https://cdn.x/w_1280,c_fill/a.jpg 1280w")
        #expect(c.map(\.url) == ["https://cdn.x/w_640,c_fill/a.jpg", "https://cdn.x/w_1280,c_fill/a.jpg"])
        #expect(c.map(\.descriptor) == ["640w", "1280w"])
        #expect(ArticlePasses.largestCandidate("a.jpg, b.jpg 2x, c.jpg 1.5x") == "b.jpg")
        #expect(ArticlePasses.absSrcset("/a.jpg 1x, b.jpg 2x", base: "https://e.com/p/") == "https://e.com/a.jpg 1x, https://e.com/p/b.jpg 2x")
    }

    @Test func absolutizeAndLazyPromotion() throws {
        let r = try ExtractFixture.root("""
        <a href="/x">x</a>
        <img src="data:image/gif;base64,R0" data-src="/lazy.jpg">
        <img srcset="/s1.jpg 400w, /s2.jpg 800w">
        <img data-asset="12345">
        <img data-asset="/clip.webp">
        <video data-src="/v.mp4" data-poster="/p.jpg"></video>
        <video data-src="/other.mp4"><source src="/s.mp4"></video>
        """)
        ArticlePasses.absolutize(r, base: "https://e.com/post/")
        let imgs = ExtractionDOM.select(r, "img")
        #expect(ExtractionDOM.attr(ExtractionDOM.select(r, "a")[0], "href") == "https://e.com/x")
        #expect(ExtractionDOM.attr(imgs[0], "src") == "https://e.com/lazy.jpg")
        #expect(ExtractionDOM.attr(imgs[1], "src") == "https://e.com/s2.jpg")
        #expect(ExtractionDOM.attr(imgs[2], "src") == nil)
        #expect(ExtractionDOM.attr(imgs[3], "src") == "https://e.com/clip.webp")
        let videos = ExtractionDOM.select(r, "video")
        #expect(ExtractionDOM.attr(videos[0], "src") == "https://e.com/v.mp4")
        #expect(ExtractionDOM.attr(videos[0], "poster") == "https://e.com/p.jpg")
        #expect(ExtractionDOM.attr(videos[1], "src") == nil)
    }

    @Test func embedSrcRewrites() {
        #expect(ArticleSanitizer.embedSrc("https://www.youtube.com/embed/abc?rel=0") == "https://www.youtube-nocookie.com/embed/abc?rel=0")
        #expect(ArticleSanitizer.embedSrc("https://player.vimeo.com/video/1?background=1&muted=1&h=x") == "https://player.vimeo.com/video/1?h=x&controls=1")
        #expect(ArticleSanitizer.embedSrc("https://player.vimeo.com/video/1?h=x") == "https://player.vimeo.com/video/1?h=x")
        #expect(ArticleSanitizer.embedSrc("https://www.youtube.com/embed/abc?autoplay=1&mute=1", watchable: false) == "https://www.youtube-nocookie.com/embed/abc")
        #expect(ArticleSanitizer.embedSrc("https://example.com/embed/x") == "https://example.com/embed/x")
    }

    @Test func hnFeedDetection() {
        #expect(DefaultContentExtractor.isHNFeed("https://hnrss.org/frontpage?points=100"))
        #expect(!DefaultContentExtractor.isHNFeed("https://news.ycombinator.com/rss"))
    }
}

@Suite("Extraction: sanitizer")
struct ExtractionSanitizerTests {
    @Test func dropsScriptsHandlersAndBadSchemes() {
        let out = ArticleSanitizer.sanitize("""
        <p onclick="x()" style="color:red">Hi <script>alert(1)</script><a href="javascript:alert(1)">bad</a> <a href="/rel" class="x-handle other">ok</a></p>
        <style>p{}</style><custom-tag>kept text</custom-tag><img src="data:image/png;base64,AA" alt=""><img src="https://e.com/a.jpg" onerror="x" class="hero">
        <!-- comment --><textarea>gone</textarea>
        """)
        #expect(!out.contains("script"))
        #expect(!out.contains("alert"))
        #expect(!out.contains("onclick"))
        #expect(!out.contains("style"))
        #expect(!out.contains("comment"))
        #expect(!out.contains("gone"))
        #expect(out.contains("<p>Hi "))
        #expect(out.contains("<a target=\"_blank\" rel=\"noopener noreferrer\">bad</a>"))
        #expect(out.contains("<a href=\"/rel\" class=\"x-handle\" target=\"_blank\" rel=\"noopener noreferrer\">ok</a>"))
        #expect(out.contains("kept text"))
        #expect(!out.contains("custom-tag"))
        #expect(!out.contains("data:image"))
        #expect(out.contains("<img src=\"https://e.com/a.jpg\" loading=\"lazy\""))
    }

    @Test func iframesOnlyFromAllowedPlayers() {
        let out = ArticleSanitizer.sanitize("""
        <iframe src="https://www.youtube.com/embed/abc" width="100%" height="315" allowfullscreen></iframe>
        <iframe src="https://evil.example.com/embed/x"><p>inside</p></iframe>
        <iframe src="https://player.vimeo.com/video/9"></iframe>
        <iframe></iframe>
        """)
        #expect(out.contains("src=\"https://www.youtube-nocookie.com/embed/abc\""))
        #expect(!out.contains("100%"))
        #expect(out.contains("height=\"315\""))
        #expect(out.contains("allowfullscreen"))
        #expect(!out.contains("evil"))
        #expect(out.contains("player.vimeo.com/video/9"))
        #expect(out.components(separatedBy: "<iframe").count == 3)
    }

    @Test func videoGetsControlsAndLosesPlaceholderPoster() {
        let out = ArticleSanitizer.sanitize("<video src=\"https://e.com/v.mp4\" poster=\"https://e.com/fallback.jpg\" preload=\"none\" onplay=\"x\"></video><video src=\"https://e.com/w.mp4\" poster=\"https://e.com/frame.jpg\"></video>")
        #expect(!out.contains("fallback.jpg"))
        #expect(out.contains("poster=\"https://e.com/frame.jpg\""))
        #expect(out.contains("controls"))
        #expect(out.contains("preload=\"metadata\""))
        #expect(!out.contains("onplay"))
    }

    @Test func svgShapesOnly() {
        let out = ArticleSanitizer.sanitize("""
        <svg viewBox="0 0 10 10" onload="x()"><defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs>
        <rect width="5" height="5" fill="url(#g)"/><rect width="5" height="5" fill="url(https://evil/x.svg)" style="x"/>
        <use href="#a"/><image href="https://evil/i.png"/><foreignObject><p>txt</p></foreignObject></svg>
        """)
        #expect(out.contains("<svg viewbox=\"0 0 10 10\">"))
        #expect(out.contains("fill=\"url(#g)\""))
        #expect(!out.contains("evil"))
        #expect(!out.contains("<use"))
        #expect(!out.contains("<image"))
        #expect(!out.contains("foreignobject"))
        #expect(!out.contains("onload"))
        #expect(out.contains("<linearGradient id=\"g\">"))
    }

    @Test func keepsCodeClassesAndTables() {
        let out = ArticleSanitizer.sanitize("<pre class=\"language-swift\"><code class=\"hljs\">let x = 1</code></pre><table><tr><td colspan=\"2\" width=\"9\">a</td></tr></table><div class=\"x-post foo\" id=\"z\">p</div>")
        #expect(out.contains("<pre class=\"language-swift\"><code class=\"hljs\">let x = 1</code></pre>"))
        #expect(out.contains("<td colspan=\"2\">a</td>"))
        #expect(out.contains("<div class=\"x-post\">p</div>"))
    }

    /// SwiftSoup keeps iframe content as raw text, but inside <svg> a browser parses it as markup and an <img> there
    /// breaks out into a live HTML element. No iframe fallback content may survive, and no iframe inside an svg.
    @Test func iframeContentCannotSmuggleMarkup() {
        let yt = "https://www.youtube-nocookie.com/embed/x"
        let payloads = [
            "<svg><iframe src=\"\(yt)\"><img src=x onerror=alert(1)></iframe></svg>",
            "<svg><p><iframe src=\"\(yt)\"><img src=x onerror=alert(1)></iframe></svg>",
            "<svg><a><iframe src=\"\(yt)\"></a><img src=x onerror=alert(1)></iframe></svg>",
            "<svg><text><iframe src=\"\(yt)\"><img src=x onerror=alert(1)></iframe></text></svg>",
            "<iframe src=\"\(yt)\"><img src=x onerror=alert(1)></iframe>",
            "<iframe src=\"\(yt)\"><script>alert(1)</script></iframe>",
        ]
        for payload in payloads {
            let out = ArticleSanitizer.sanitize(payload)
            #expect(!out.contains("onerror"), "\(payload) -> \(out)")
            #expect(!out.contains("alert"), "\(payload) -> \(out)")
            #expect(!out.contains("<img"), "\(payload) -> \(out)")
        }
        #expect(!ArticleSanitizer.sanitize(payloads[0]).contains("<iframe"))
        #expect(ArticleSanitizer.sanitize(payloads[4]) == "<iframe src=\"\(yt)\"></iframe>")
    }

    @Test func srcsetFiltered() {
        let out = ArticleSanitizer.sanitize("<img src=\"https://e.com/a.jpg\" srcset=\"javascript:x 1x, https://e.com/b.jpg 2x\">")
        #expect(out.contains("srcset=\"https://e.com/b.jpg 2x\""))
    }
}

@Suite("Extraction: pre-Readability passes")
struct ExtractionPrePassTests {
    @Test func screenReaderTextRemoved() throws {
        let r = try ExtractFixture.root("""
        <p>Read <span class="sr-only">(opens in new tab)</span>more<span class="sr-only sm:not-sr-only">Visible label</span>
        <span style="position:absolute;width:1px;height:1px">hidden</span><span aria-hidden="true">↗</span><span aria-hidden="true">Words</span></p>
        """)
        ArticlePasses.removeScreenReaderText(r)
        let text = ExtractionDOM.text(r)
        #expect(!text.contains("opens in new tab"))
        #expect(text.contains("Visible label"))
        #expect(!text.contains("hidden"))
        #expect(!text.contains("↗"))
        #expect(text.contains("Words"))
    }

    @Test func playerChromeRemovedButProseTimestampsKept() throws {
        let r = try ExtractFixture.root("""
        <div class="player"><video src="v.mp4"></video><div><button>Play</button><span>00:00 / 01:59</span></div><div role="slider">x</div></div>
        <ul><li>00:42 Intro</li></ul><ol><li><span>12:30</span></li></ol>
        """)
        ArticlePasses.removePlayerChrome(r)
        let text = ExtractionDOM.text(r)
        #expect(!text.contains("01:59"))
        #expect(ExtractionDOM.first(r, "[role=slider]") == nil)
        #expect(text.contains("00:42 Intro"))
        #expect(text.contains("12:30"))
    }

    @Test func numberedCodeRowsBecomePlainCode() throws {
        let r = try ExtractFixture.root("""
        <code class="language-py"><pre><div><span>1</span><div>import os</div></div><div><span>2</span><div>print(os.name)</div></div></pre></code>
        <table><tr><td><pre>1
        2</pre></td><td><pre>a = 1
        b = 2</pre></td></tr></table>
        """)
        ArticlePasses.normalizeCodeBlocks(r)
        let pres = ExtractionDOM.select(r, "pre")
        #expect(pres.count == 2)
        let code = try #require(ExtractionDOM.first(pres[0], "code"))
        #expect(ExtractionDOM.attr(code, "class") == "language-py")
        #expect(ExtractionDOM.rawText(code) == "import os\nprint(os.name)")
        #expect(ExtractionDOM.first(r, "table") == nil)
        #expect(ExtractionDOM.rawText(pres[1]).contains("a = 1"))
    }

    @Test func darkVariantDropped() throws {
        let r = try ExtractFixture.root("<figure><img class=\"light-mode\" src=\"l.png\"><img class=\"dark-mode-alternative\" src=\"d.png\"></figure><figure><img class=\"hidden dark:block\" src=\"d2.png\"><img class=\"dark:hidden\" src=\"l2.png\"></figure><p><img class=\"dark\" src=\"solo.png\"></p>")
        ArticlePasses.dropDarkVariants(r)
        let srcs = ExtractionDOM.select(r, "img").compactMap { ExtractionDOM.attr($0, "src") }
        #expect(srcs == ["l.png", "l2.png", "solo.png"])
    }

    @Test func utilityClassesNeutralized() throws {
        let r = try ExtractFixture.root("<div class=\"overflow-hidden sidebar md:flex\"><h2 id=\"related-work\" class=\"section-header scroll-mt-[72px]\">Related work</h2><figure class=\"media-figure\"><img src=\"a.png\"></figure></div>")
        ArticlePasses.neutralizeReadabilityClasses(r)
        let div = try #require(ExtractionDOM.first(r, "div"))
        #expect(ExtractionDOM.classTokens(div) == ["sidebar", "md:flex"])
        let h2 = try #require(ExtractionDOM.first(r, "h2"))
        #expect(ExtractionDOM.attr(h2, "id") == nil)
        #expect(ExtractionDOM.classTokens(h2).isEmpty)
        #expect(ExtractionDOM.classTokens(try #require(ExtractionDOM.first(r, "figure"))).isEmpty)
    }

    @Test func protectAndRestoreMedia() throws {
        let r = try ExtractFixture.root("<div><svg viewBox=\"0 0 400 300\"><rect width=\"4\" height=\"4\"/></svg></div><div><video src=\"v.mp4\"></video></div><button><svg width=\"16\" height=\"16\"></svg></button>")
        let saved = ArticlePasses.protectMedia(r)
        #expect(saved.count == 2)
        let html = ExtractFixture.html(r)
        #expect(html.contains("opendispatch.invalid/media/0"))
        #expect(html.contains("width=\"16\""))
        let restored = ArticlePasses.restoreMedia(html, saved)
        #expect(restored.contains("<rect"))
        #expect(restored.contains("<video src=\"v.mp4\">"))
        #expect(!restored.contains("opendispatch.invalid"))
    }

    @Test func splitContainersMerged() throws {
        let p = "<p>\(ExtractFixture.para)</p>"
        let doc = try #require(ExtractionDOM.parseDocument("<article><div class=\"post-content\">\(p)</div><div class=\"ad\">Advertisement</div><div class=\"post-content\">\(p)<p>Second part.</p></div></article>"))
        ArticlePasses.mergeSplitContainers(doc)
        let blocks = ExtractionDOM.select(doc, ".post-content")
        #expect(blocks.count == 1)
        #expect(ExtractionDOM.text(blocks[0]).contains("Second part."))

        let doc2 = try #require(ExtractionDOM.parseDocument("<main><div class=\"post-content\">\(p)</div><h2>Another story</h2><div class=\"post-content\">\(p)</div></main>"))
        ArticlePasses.mergeSplitContainers(doc2)
        #expect(ExtractionDOM.select(doc2, ".post-content").count == 2)
    }

    @Test func clientRenderedFigureGetsLink() throws {
        let r = try ExtractFixture.root("<figure id=\"chart-1\"><div></div><figcaption>Revenue by year</figcaption></figure><figure><img src=\"a.png\"><figcaption>Real</figcaption></figure>")
        ArticlePasses.markClientRenderedFigures(r, pageURL: "https://e.com/post#top")
        let html = ExtractFixture.html(r)
        #expect(html.contains("Interactive figure not shown here"))
        #expect(html.contains("href=\"https://e.com/post#chart-1\""))
        #expect(html.components(separatedBy: "Interactive figure").count == 2)
    }

    @Test func payloadVideoPlacedInEmptySlot() throws {
        let payload = #"1e:["$","div",null,{"children":"This paragraph introduces the demo video that follows right below it."}]"# + "\n"
            + #"1f:{"altText":"Demo clip","videoEmbedUrl":"https://player.vimeo.com/video/12345?h=abc","videoEmbedTitle":"Demo","posterImage":{"title":"Demo poster","file":{"url":"https://cdn.e.com/poster-demo.jpg"}}}"#
        let literal = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]), encoding: .utf8) ?? ""
        let html = "<html><body><p>Intro</p><figure><div data-video-container></div></figure><script>self.__next_f.push([1,\(literal)])</script></body></html>"
        let videos = ExtractionPayload.videos(in: html)
        #expect(videos.count == 1)
        let v = try #require(videos.first)
        #expect(v.key == "12345")
        #expect(v.names == ["Demo clip", "Demo poster"])
        #expect(v.posterFile == "poster-demo.jpg")
        #expect(v.anchor == "This paragraph introduces the demo video that follows right below it.")

        let doc = try #require(ExtractionDOM.parseDocument("<p>This paragraph introduces the demo video that follows right below it.</p><figure><img alt=\"Demo poster\" src=\"https://cdn.e.com/x.jpg\"></figure>"))
        ArticlePasses.placePayloadVideos(doc, videos)
        let iframe = try #require(ExtractionDOM.first(doc, "figure iframe"))
        #expect(ExtractionDOM.attr(iframe, "src") == "https://player.vimeo.com/video/12345?h=abc&controls=1")
        #expect(ExtractionDOM.first(doc, "figure img") == nil)
    }
}

@Suite("Extraction: cleanArticle")
struct ExtractionCleanTests {
    @Test func removesAuthorCardsAvatarsIconsAndNavTables() {
        let p = "<p>\(ExtractFixture.para)</p>"
        let html = """
        \(p)
        <div class="byline"><img src="https://e.com/a.jpg" width="48" height="48"><a href="/author/jane">Jane</a></div>
        <p>Inline <img src="https://secure.gravatar.com/avatar/x?s=64"> avatar</p>
        <p><svg width="16" height="16"><path d="M0 0"/></svg>Icon</p>
        <table><tr><td><a href="/1">One</a></td><td><a href="/2">Two</a></td><td><a href="/3">Three</a></td><td><a href="/4">Four</a></td></tr></table>
        \(p)
        """
        let out = ArticlePasses.cleanArticle(html, base: "https://e.com/")
        #expect(!out.contains("Jane"))
        #expect(!out.contains("gravatar"))
        #expect(!out.contains("<svg"))
        #expect(!out.contains("<table"))
        #expect(out.contains("Icon"))
    }

    @Test func removesBoilerplateLines() {
        let p = "<p>\(ExtractFixture.para)</p>"
        let html = """
        <p>When you purchase through links in our articles, we may earn a small commission.</p>
        \(p)\(p)
        <p>Share this article</p>
        <p>He said “we may earn a commission on purchases through links” was the plan.</p>
        <h3>Related articles</h3>
        <p>Jane Doe is a senior reporter covering AI. Follow her on Twitter.</p>
        """
        let out = ArticlePasses.cleanArticle(html, base: nil)
        #expect(!out.contains("purchase through links"))
        #expect(!out.contains("Share this"))
        #expect(out.contains("was the plan"))
        #expect(!out.contains("Related articles"))
        #expect(!out.contains("senior reporter"))
        #expect(out.contains("OpenDispatch reads"))
    }

    @Test func followTopicsFooterRemoved() {
        let p = "<p>\(ExtractFixture.para)</p>"
        let html = """
        \(p)<p><em>This is a developing story...</em></p>
        <div><p><strong>Follow topics and authors</strong> from this story to see more like this in your personalized homepage feed and to receive email updates.</p>
        <ul><li>Robert Hart</li><li></li><li></li><li>AI</li></ul></div>
        """
        let out = ArticlePasses.cleanArticle(html, base: nil)
        #expect(!out.contains("Follow topics"))
        #expect(!out.contains("Robert Hart"))
        #expect(!out.contains("<li"))
        #expect(out.contains("developing story"))
    }

    @Test func emptySectionLabelsDropped() {
        let p = "<p>\(ExtractFixture.para)</p>"
        let out = ArticlePasses.cleanArticle("<h2>Intro</h2>\(p)<h2>Empty</h2><h2>Next</h2>\(p)<p><strong>Links:</strong></p>", base: nil)
        #expect(out.contains("Intro"))
        #expect(!out.contains("Empty"))
        #expect(out.contains("Next"))
        #expect(!out.contains("Links:"))
    }

    @Test func deadMediaAndPostersRemoved() {
        let out = ArticlePasses.cleanArticle("""
        <figure><div><div><img alt="Video poster" src="https://e.com/p.jpg"></div></div><iframe src="https://player.vimeo.com/video/1"></iframe></figure>
        <div><video></video></div>
        <div><video src="https://e.com/v.mp4" poster="https://e.com/f.jpg"></video><img src="https://e.com/f.jpg"></div>
        """, base: nil)
        #expect(!out.contains("p.jpg"))
        #expect(!out.contains("<video></video>"))
        #expect(out.components(separatedBy: "f.jpg").count == 2)
    }

    @Test func firstImageSkipsBadgesAndLogos() {
        let html = """
        <img src="https://img.shields.io/badge/build-passing-green.svg">
        <img src="https://e.com/logo.png">
        <img src="https://e.com/small.png" width="200">
        <img src="https://e.com/strip.png" width="300" height="20">
        <img src="https://e.com/hero.jpg" width="1200">
        """
        #expect(ArticlePasses.firstImage(html) == "https://e.com/hero.jpg")
    }
}

@Suite("Extraction: extractFromHtml and feed copy")
struct ExtractionFlowTests {
    @Test func preferFeedRule() {
        let short = "<p>\(String(repeating: "a ", count: 200))</p>"
        let long = "<p>\(String(repeating: "b ", count: 1000))</p>"
        #expect(ArticleExtraction.preferFeed(pageHTML: short, feedHTML: long))
        #expect(!ArticleExtraction.preferFeed(pageHTML: long, feedHTML: short))
        #expect(ArticleExtraction.preferFeed(pageHTML: nil, feedHTML: long))
        #expect(!ArticleExtraction.preferFeed(pageHTML: nil, feedHTML: "<p>teaser</p>"))
    }

    @Test func feedHTMLTeaserVsFull() {
        #expect(ArticleExtraction.extractFromFeedHTML("<p>Just a teaser.</p>", pageURL: "https://e.com/a").contentHtml == nil)
        let full = ArticleExtraction.extractFromFeedHTML("<p>\(ExtractFixture.para)</p><p>\(ExtractFixture.para)</p><img src=\"/hero.jpg\"><script>x</script>", pageURL: "https://e.com/a")
        let html = full.contentHtml
        #expect(html?.contains("https://e.com/hero.jpg") == true)
        #expect(html?.contains("script") == false)
        #expect(full.leadImage == "https://e.com/hero.jpg")
    }

    @Test func podcastPlainNotesBecomeParagraphs() {
        let out = ArticleExtraction.podcastNotes("First line\nsecond line\n\nNext & more", pageURL: "https://e.com/ep")
        #expect(out.contentHtml == "<p>First line<br>second line</p><p>Next &amp; more</p>")
        #expect(out.leadImage == nil)
        let tagged = ArticleExtraction.podcastNotes("<p>Show <a href=\"/links\">links</a></p>", pageURL: "https://e.com/ep")
        #expect(tagged.contentHtml?.contains("href=\"https://e.com/links\"") == true)
    }

    @Test func pickedOutsideRegionDetection() {
        let story = (1...3).map { "<p>Story paragraph number \($0) with enough words to count as distinctive text.</p>" }.joined()
        let legal = (1...3).map { "<p>Legal disclaimer clause \($0) that has nothing to do with the story at all.</p>" }.joined()
        #expect(ArticleExtraction.pickedOutsideRegion(contentHTML: legal, regionHTML: "<div><h1>T</h1>\(story)</div>"))
        #expect(!ArticleExtraction.pickedOutsideRegion(contentHTML: story, regionHTML: "<div><h1>T</h1>\(story)</div>"))
    }

    @Test func extractWithFakeReadability() async throws {
        let p = "<p>\(ExtractFixture.para)</p>"
        let html = """
        <!doctype html><html><head><title>Hello</title><meta property="og:image" content="/og.jpg"></head><body>
        <article><h1>Hello</h1>\(p)<div class="chart"><svg viewBox="0 0 400 300"><rect width="4" height="4"/></svg></div>\(p)
        <p class="sr-only">Skip to content</p><a href="/more">More</a></article></body></html>
        """
        let seen = LockedBox<String>("")
        let engine = FakeReadability(calls: { seen.set($0) })
        let out = try await ArticleExtraction(readability: engine).extract(html: html, pageURL: "https://e.com/post")
        let body = try #require(out.contentHtml)
        #expect(out.leadImage == "https://e.com/og.jpg")
        #expect(body.contains("<svg"))
        #expect(!body.contains("Skip to content"))
        #expect(body.contains("href=\"https://e.com/more\""))
        // Readability saw the placeholder, not the svg.
        #expect(seen.get().contains("opendispatch.invalid/media/0"))
        #expect(!seen.get().contains("<rect"))
    }

    @Test func extractLeadFallsBackToFirstImage() async throws {
        let p = "<p>\(ExtractFixture.para)</p>"
        let html = "<html><body><article>\(p)<img src=\"https://e.com/logo.svg\"><img src=\"/big.jpg\">\(p)</article></body></html>"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: "https://e.com/x")
        #expect(out.leadImage == "https://e.com/big.jpg")
    }

    @Test func heroVideoPutFirst() async throws {
        let paras = (1...3).map { "<p>Body paragraph \($0) of the article that follows the hero video in the header.</p>" }.joined()
        let html = """
        <html><head><title>Launch</title></head><body>
        <header><h1>Launch</h1><figure><iframe src="https://player.vimeo.com/video/777?background=1"></iframe></figure></header>
        <article>\(paras)</article></body></html>
        """
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: "https://e.com/l")
        let body = try #require(out.contentHtml)
        #expect(body.hasPrefix("<iframe src=\"https://player.vimeo.com/video/777?controls=1\""))
    }

    @Test func loginWallDetection() {
        #expect(ArticleExtraction.isLoginWall("<p>Log in to continue reading</p>"))
        #expect(!ArticleExtraction.isLoginWall("<p>\(ExtractFixture.para)</p>"))
    }

    @Test func valueWithinTimesOut() async {
        let slow = Task<Int?, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
        let start = Date()
        let v = await DefaultContentExtractor.value(of: slow, within: 0.1)
        #expect(v == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        let fast = Task<Int?, Never> { 7 }
        #expect(await DefaultContentExtractor.value(of: fast, within: 2) == 7)
    }
}

@Suite("Extraction: X posts")
struct ExtractionTweetTests {
    /// Builds X's escaped page data: JSON inside a JSON string inside the HTML.
    static func escaped(_ json: String) -> String {
        json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @Test func postFromPageData() throws {
        let data = Self.escaped(#"{"core":{"name":"Jane & Co","screen_name":"jane"},"legacy":{"created_at_ms":1792865465000,"full_text":"Hello @bob\n\nSee https://t.co/abc","entities":{"urls":[{"display_url":"example.com/post","expanded_url":"https://example.com/post","indices":[1,2],"url":"https://t.co/abc"}]}}}"#)
        let raw = "<html><head><meta property=\"og:title\" content=\"Jane (@jane) on X\"></head><body><script>window.x=\"\(data)\"</script></body></html>"
        let out = try #require(TweetExtraction.fromPage(raw: raw, canonical: "https://x.com/jane/status/1", user: "jane"))
        let html = try #require(out.contentHtml)
        #expect(html.contains("<div class=\"x-post\">"))
        #expect(html.contains("<span class=\"x-name\">Jane &amp; Co</span>"))
        #expect(html.contains("href=\"https://x.com/bob\""))
        #expect(html.contains("href=\"https://example.com/post\""))
        #expect(html.contains(">example.com/post</a>"))
        #expect(html.contains("<span>Oct 24, 2026</span>"))
        #expect(html.contains("Open on X"))
    }

    @Test func mediaOnlyPost() throws {
        let data = Self.escaped(#"{"core":{"name":"Al","screen_name":"al"},"details":{"created_at_ms":1793047057000,"display_text_range":[0,0],"full_text":"https://t.co/m1"},"media_entities2":[{"expanded_url":"https://x.com/al/status/1/photo/1","indices":[0,23],"media_url_https":"https://pbs.twimg.com/media/A.jpg","original_info":{"height":1254,"width":1254},"type":"photo"},{"media_url_https":"https://pbs.twimg.com/amplify_video_thumb/2/img/B.jpg","original_info":{"height":1080,"width":1920},"type":"video","video_info":{"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/b.m3u8"},{"bitrate":832000,"content_type":"video/mp4","url":"https://video.twimg.com/lo.mp4"},{"bitrate":2176000,"content_type":"video/mp4","url":"https://video.twimg.com/hi.mp4"}]}},{"media_url_https":"https://pbs.twimg.com/tweet_video_thumb/C.jpg","type":"animated_gif","video_info":{"variants":[{"bitrate":0,"content_type":"video/mp4","url":"https://video.twimg.com/tweet_video/C.mp4"}]}}],"mention_entities":[]}"#)
        let raw = "<html><body><script>window.x=\"\(data)\"</script></body></html>"
        let html = try #require(TweetExtraction.fromPage(raw: raw, canonical: "https://x.com/al/status/1", user: "al")?.contentHtml)
        #expect(!html.contains("t.co"))
        #expect(!html.contains("x-body"))
        #expect(html.contains("<div class=\"x-media x-media-grid\">"))
        #expect(html.contains("src=\"https://pbs.twimg.com/media/A.jpg?name=large\""))
        #expect(html.contains("src=\"https://video.twimg.com/hi.mp4\""))
        #expect(html.contains("poster=\"https://pbs.twimg.com/amplify_video_thumb/2/img/B.jpg\""))
        #expect(html.contains("src=\"https://video.twimg.com/tweet_video/C.mp4\""))
        #expect(html.contains("loop"))
    }

    @Test func mediaLinkDroppedButRealLinkKept() {
        let links: TweetExtraction.Links = ["https://t.co/real": ("e.com", "https://e.com")]
        #expect(TweetExtraction.withoutMediaLinks("Look https://t.co/real https://t.co/m1", links: links) == "Look https://t.co/real")
    }

    @Test func oEmbedFallback() {
        let out = TweetExtraction.fromOEmbed(html: "<blockquote class=\"twitter-tweet\"><p lang=\"en\">Short <a href=\"https://t.co/x\">post</a></p>&mdash; Jane</blockquote>", authorName: "Jane", authorURL: "https://twitter.com/jane", canonical: "https://x.com/jane/status/1")
        #expect(out?.contentHtml?.hasPrefix("<blockquote><p>Short <a href=\"https://t.co/x\"") == true)
        #expect(out?.contentHtml?.contains("Jane</a> on X") == true)
    }

    @Test func tweetURLs() {
        #expect(TweetExtraction.tweetURL.test("https://twitter.com/a/status/123"))
        #expect(TweetExtraction.tweetURL.test("https://mobile.x.com/a/status/123?s=20"))
        #expect(!TweetExtraction.tweetURL.test("https://x.com/a"))
    }
}

/// Minimal thread-safe box for capturing values from @Sendable closures.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
