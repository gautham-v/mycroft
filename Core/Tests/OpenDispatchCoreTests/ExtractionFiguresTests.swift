import Foundation
import Testing
@testable import OpenDispatchCore

/// Figures the extractor lost or replaced although the page has them (The Conversation, Pitchfork, Noahpinion and other
/// Substacks, NASA, IGN, the Daily Mail, E! Online).
@Suite("Extraction: figures")
struct ExtractionFiguresTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func page(_ body: String, head: String = "") -> String {
        "<html><head><title>T</title>\(head)</head><body><article>\(p)\(body)\(p)</article></body></html>"
    }

    // MARK: pictures behind page controls

    @Test func zoomableImageIsNotAnInterfaceButton() async throws {
        let html = page("""
        <figure class="align-center zoomable"><a role="button" aria-label="Zoomable image" aria-haspopup="dialog" href="https://e.com/big.jpg"><div class="placeholder-container"><img alt="A protest" src="https://e.com/p.jpg" width="754" height="524"></div></a><figcaption>A caption</figcaption></figure>
        """)
        let body = try await extract(html)
        #expect(body.contains("https://e.com/p.jpg"))
        #expect(!body.contains("Interactive figure not shown here"))
        #expect(body.contains("A caption"))
    }

    @Test func shortButtonsWithoutPicturesStillGo() async throws {
        let html = page(##"<p><a role="button" aria-haspopup="dialog" href="#">Share</a></p>"##)
        let body = try await extract(html)
        #expect(!body.contains("Share"))
    }

    @Test func placeholderImageInALinkToThePictureTakesTheLink() async throws {
        let html = page("""
        <figure><a href="https://assets.e.com/2026/sin-city.webp"><img alt="" aria-hidden="true" role="presentation" loading="lazy" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></a><figcaption>Art by Frank Miller.</figcaption></figure>
        """)
        let body = try await extract(html)
        #expect(body.contains("src=\"https://assets.e.com/2026/sin-city.webp\""))
        #expect(body.contains("Art by Frank Miller."))
    }

    @Test func placeholderImageInALinkToAPageStaysAPlaceholder() async throws {
        let html = page("""
        <figure><a href="https://e.com/gallery"><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></a></figure>
        """)
        let body = try await extract(html)
        #expect(!body.contains("src=\"https://e.com/gallery"))
    }

    @Test func shareClassIsDroppedFromPicturesOnly() throws {
        let doc = try #require(ExtractionDOM.parseDocument("""
        <body><div class="mol-img"><img class="blkBorder img-share" src="https://e.com/a.jpg" width="634" height="925"></div>
        <div class="share-bar"><img class="share-icon" src="https://e.com/fb.png" width="24" height="24"></div></body>
        """, baseURI: "https://e.com/"))
        ArticlePasses.dropShareClassFromImages(doc)
        #expect(ExtractionDOM.classTokens(try #require(ExtractionDOM.first(doc, "img[src$='a.jpg']"))) == ["blkBorder"])
        #expect(ExtractionDOM.classTokens(try #require(ExtractionDOM.first(doc, "img[src$='fb.png']"))) == ["share-icon"])
        #expect(ExtractionDOM.classTokens(try #require(ExtractionDOM.first(doc, ".share-bar"))) == ["share-bar"])
    }

    @Test func boxesAroundACaptionedFigureLoseTheirLayoutWords() throws {
        let doc = try #require(ExtractionDOM.parseDocument("""
        <body><div class="hds-media hds-module"><div class="hds-media-wrapper"><figure class="hds-cover-wrapper"><img src="https://e.com/a.jpg"></figure><figcaption>Credit: NASA</figcaption></div></div>
        <div class="media-and-text"><figure><img src="https://e.com/b.jpg"></figure><p>Text beside the picture.</p></div></body>
        """, baseURI: "https://e.com/"))
        ArticlePasses.neutralizeFigureWrappers(doc)
        #expect(ExtractionDOM.select(doc, "[class*=media], [class*=cover]").map { ExtractionDOM.classTokens($0) } == [["media-and-text"]])
    }

    @Test func aFigureHoldingMoreThanItsCaptionIsLeftToReadability() throws {
        let doc = try #require(ExtractionDOM.parseDocument("""
        <body><figure><img src="https://e.com/lead.jpg"><div><h1>The title</h1></div><figcaption>Cap <a href="https://e.com/credit">Credit</a></figcaption></figure>
        <figure><img src="https://e.com/c.png"><figcaption>Source: <a href="https://e.com/paper">Paper</a></figcaption></figure></body>
        """, baseURI: "https://e.com/"))
        let saved = ArticlePasses.protectMedia(doc)
        #expect(saved.count == 1)
        #expect(saved[0].contains("c.png"))
        #expect(ExtractionDOM.first(doc, "h1") != nil)
    }

    // MARK: players the page mounts

    @Test func substackVideoUploadsBecomeVideos() async throws {
        let html = page("""
        <div data-component-name="VideoEmbedPlayer" data-media-upload-id="6b400a33-c0ee-4575-8a72-1511ae0e28ae" id="media-6b400a33" class="videoScrollTarget"><div class="placeholder" style="height:400px"></div></div>
        <div class="native-video-embed" data-component-name="VideoPlaceholder" data-attrs="{&quot;mediaUploadId&quot;:&quot;1fa972c7-df35-4e00-b112-4990e084a4b3&quot;,&quot;duration&quot;:null}"></div>
        """)
        let body = try await extract(html)
        #expect(body.contains("src=\"https://substack.com/api/v1/video/upload/6b400a33-c0ee-4575-8a72-1511ae0e28ae/src?type=mp4\""))
        #expect(body.contains("src=\"https://substack.com/api/v1/video/upload/1fa972c7-df35-4e00-b112-4990e084a4b3/src?type=mp4\""))
    }

    static let condeData = """
    <script>window.__PRELOADED_STATE__ = {"body":[["p","x"],["inline-embed",{"props":{"sandbox":"allow-scripts","dangerousCaption":"","height":"275","url":"https:\\u002F\\u002Fembed.tidal.com\\u002Falbums\\u002F574136505","width":"500"},"level":"block","ref":"","type":"iframe"}],["ad",{"position":"mid-content"}],["inline-embed",{"props":{"aspectRatio":"16:9","dangerousCaption":"","height":"","url":"https:\\u002F\\u002Fwww.youtube-nocookie.com\\u002Fembed\\u002Fq-wiRleLRYk","width":""},"level":"block","ref":"","type":"video"}]]}</script>
    """
    static let condeSlot = #"<figure data-testid="IframeEmbed" class="iframe-embed"><div data-testid="IframeEmbedContainer"></div></figure>"#

    @Test func emptyIframeEmbedFiguresAreFilledFromThePageData() async throws {
        let html = page(Self.condeSlot + p + Self.condeSlot, head: Self.condeData)
        let body = try await extract(html)
        #expect(body.contains("src=\"https://embed.tidal.com/albums/574136505\""))
        #expect(body.contains("youtube-nocookie.com/embed/q-wiRleLRYk"))
        #expect(body.contains("width=\"500\""))
        #expect(!body.contains("Interactive figure not shown here"))
    }

    @Test func embedSlotsWithoutAMatchingCountStayEmpty() async throws {
        let html = page(Self.condeSlot, head: Self.condeData)
        let body = try await extract(html)
        #expect(!body.contains("<iframe"))
    }

    // MARK: E! Online galleries

    static let apollo = """
    <script>window.__APOLLO_STATE__= {"Gallery:1":{"__typename":"Gallery","galleryitems({\\"filter\\":{\\"limit\\":30}})":{"nodes":[{"title":"<p>Blue Ivy The Dancer&nbsp;</p>","caption":"<p>c</p>","image({\\"edition\\":\\"US\\"})":{"__ref":"Image:1"}},{"title":"An Audiobook Narrator","image({\\"edition\\":\\"US\\"})":{"__ref":"Image:2"}}]}},"Image:1":{"uri":"https://img.e.com/dancer.jpg","agency":"Mason Poole"},"Image:2":{"uri":"https://img.e.com/narrator.jpg"},"Image:3":{"uri":"https://img.e.com/kern.jpg","agency":"Chloe Kern/WireImage"}}</script>
    """

    @Test func eonlineGallerySlidesGetTheirPicturesFromTheApolloState() async throws {
        let slide = { (title: String, credit: String) in
            """
            <figure data-testid="adp-vgallery-item"><div data-testid="adp-vgallery-img"><div><div class="article-detail__image-wrap"><span style="padding-top:74%" class="thumb"></span>\(credit)</div></div></div>
            <figcaption><div data-testid="adp-vgallery-title"><h2>\(title)</h2></div><div><p>Caption text for \(title).</p></div></figcaption></figure>
            """
        }
        let loose = #"<section><div class="article-detail__image-wrap"><span class="thumb"></span><span data-hook="adp-photo-agency">Chloe Kern/WireImage</span></div></section>"#
        let html = page(slide("Blue Ivy The Dancer", #"<span data-hook="adp-photo-agency">Mason Poole</span>"#) + slide("An Audiobook Narrator", "") + loose, head: Self.apollo)
        let body = try await extract(html).replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
        #expect(body.contains("src=\"https://img.e.com/dancer.jpg\""))
        #expect(body.contains("src=\"https://img.e.com/narrator.jpg\""))
        #expect(body.contains("src=\"https://img.e.com/kern.jpg\""))
        #expect(!body.contains("Interactive figure not shown here"))
        // The credit reads as part of the caption, not as a line beside the picture.
        #expect(body.contains("Mason Poole</p></figcaption>"))
        #expect(body.range(of: #"<figcaption>\s*Chloe Kern/WireImage\s*</figcaption>"#, options: .regularExpression) != nil)
    }
}

/// What only the real Readability does to a figure.
@Suite("Extraction: figures in Readability", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionFiguresWebKitTests {
    static let para = String(repeating: "Charts and photos should survive the article parser untouched here. ", count: 8)

    @MainActor func extract(_ body: String) async throws -> String {
        let html = "<!doctype html><html><head><title>Story</title></head><body><article><h1>Story</h1><p>\(Self.para)</p>\(body)<p>\(Self.para)</p><p>\(Self.para)</p></article></body></html>"
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: "https://example.com/a")
        return try #require(out.contentHtml)
    }

    @Test @MainActor func aSourceLinkInTheCaptionDoesNotCostTheChart() async throws {
        let body = try await extract("""
        <div class="captioned-image-container"><figure><a class="image-link" href="https://example.com/c.png"><div class="image2-inset"><img src="https://example.com/c.png" width="877" height="415"></div></a><figcaption class="image-caption"><span>Source: </span><a href="https://example.com/paper">Ober et al. (2026)</a></figcaption></figure></div>
        """)
        #expect(body.contains("https://example.com/c.png"))
        #expect(body.contains("Ober et al. (2026)"))
    }

    @Test @MainActor func aPictureClassedShareSurvives() async throws {
        let body = try await extract("""
        <div class="artSplitter mol-img-group"><div class="mol-img"><div class="image-wrap"><img src="https://example.com/p.jpg" width="634" height="925" class="blkBorder img-share"></div></div><p class="imageCaption">Brooklyn and Nicola twin</p></div>
        """)
        #expect(body.contains("https://example.com/p.jpg"))
    }

    @Test @MainActor func aCaptionedFigureInMediaNamedBoxesSurvives() async throws {
        let body = try await extract("""
        <div id="" class="hds-media hds-module wp-block-image"><div class="margin-left-auto nasa-block-align-inline"><div class="hds-media-wrapper"><figure class="hds-media-inner hds-cover-wrapper"><a href="https://example.com/s.jpg"><img src="https://example.com/s.jpg" width="2048" height="1582"></a></figure><figcaption class="hds-caption"><div class="hds-caption-text">This slice of a Martian meteorite was used to study its mineralogy.</div><div class="hds-credits">Credit: NASA/JPL-Caltech</div></figcaption></div></div></div>
        """)
        #expect(body.contains("https://example.com/s.jpg"))
        #expect(body.contains("Credit: NASA/JPL-Caltech"))
    }

    @Test @MainActor func tidalPlayerSurvives() async throws {
        let body = try await extract(#"<figure><iframe src="https://embed.tidal.com/albums/574136505" width="500" height="275"></iframe></figure>"#)
        #expect(body.contains("https://embed.tidal.com/albums/574136505"))
    }
}
