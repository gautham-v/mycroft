import Foundation
import Testing
@testable import OpenDispatchCore

/// Body images: lazy sources, the width they are drawn at, copies of one picture, and figures Readability would drop
/// (PCMag, DW, IGN, Vox, Eater, Axios, Guardian, Billboard, Ghost, The Conversation, Daily Mail, NASA, Substack, Quanta).
@Suite("Extraction: images")
struct ExtractionImagesTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func article(_ inner: String) -> String {
        "<html><head><title>T</title></head><body><article><h1>T</h1>\(inner)</article></body></html>"
    }

    // MARK: Sources

    @Test func lazyAddressesInUnusualAttributesBecomeTheSrc() async throws {
        let body = try await extract(article("""
        \(p)<img src="data:image/svg+xml,%3Csvg%3E%3C/svg%3E" data-image-loader="https://i.pcmag.com/imagery/a-2.jpg" alt="The Delta">
        <figure><a href="https://assets.ign.com/big.webp"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></a><figcaption>Art by Frank Miller</figcaption></figure>
        <figure><img data-url="https://static.dw.com/image/79790860_${formatId}.jpg" alt="Banners"><figcaption>Likud</figcaption></figure>\(p)
        """))
        #expect(body.contains("src=\"https://i.pcmag.com/imagery/a-2.jpg\""))
        #expect(body.contains("src=\"https://assets.ign.com/big.webp\""))
        #expect(body.contains("src=\"https://static.dw.com/image/79790860_6.jpg\""))
        #expect(!body.contains("formatId"))
    }

    @Test func aPlaceholderInALinkToAPageIsLeftAlone() {
        let root = ExtractionDOM.parseDocument("<a href=\"https://e.com/article\"><img src=\"data:image/gif;base64,AAAA\"></a>", baseURI: "https://e.com/")
        ArticlePasses.promoteLazyImages(root!)
        #expect(ExtractionDOM.first(root!, "img").flatMap { ExtractionDOM.attr($0, "src") }?.hasPrefix("data:") == true)
    }

    // MARK: Pictures

    @Test func aPictureTakesItsBiggestSourceWhenTheImgIsTheSmallFallback() async throws {
        let picture = """
        <picture><source srcset="https://i.guim.co.uk/m/1688.jpg?width=620&amp;dpr=2&amp;s=none" media="(min-width: 980px) and (min-resolution: 120dpi)">
        <source srcset="https://i.guim.co.uk/m/1688.jpg?width=700&amp;dpr=2&amp;s=none" media="(min-width: 740px) and (min-resolution: 120dpi)">
        <source srcset="https://i.guim.co.uk/m/1688.jpg?width=445&amp;dpr=1&amp;s=none" media="(min-width: 320px)">
        <img alt="Lina" src="https://i.guim.co.uk/m/1688.jpg?width=445&amp;dpr=1&amp;s=none" width="445" height="296"></picture>
        """
        let body = try await extract(article("\(p)<figure>\(picture)<figcaption>Lina in 2015</figcaption></figure>\(p)"))
        #expect(body.contains("width=700&amp;dpr=2"))
        #expect(!body.contains("width=\"445\""))
        #expect(!body.contains("<picture"))
    }

    @Test func aWideEnoughImgKeepsItsOwnSource() async throws {
        let picture = """
        <picture><source srcset="https://e.com/a.jpg?width=900&amp;dpr=2"><img src="https://e.com/a.jpg?width=900" width="900" height="600"></picture>
        """
        let body = try await extract(article("\(p)\(picture)\(p)"))
        #expect(body.contains("src=\"https://e.com/a.jpg?width=900\""))
    }

    @Test func aNarrowSlotInSizesIsDroppedForTheColumn() {
        let set = "https://e.com/a.jpg?w=376 376w, https://e.com/a.jpg?w=1080 1080w, https://e.com/a.jpg?w=2400 2400w"
        let out = ArticlePasses.cleanArticle("""
        <img src="https://e.com/a.jpg?w=2400" srcset="\(set)" sizes="(max-width: 639px) 100vw, (max-width: 1023px) 50vw, 700px" alt="panel">
        <img src="https://e.com/b.jpg" srcset="\(set)" sizes="(min-width: 87.5rem) 1000px, (min-width: 48rem) 450px, (max-width: 48rem) 100vw" alt="lead">
        <img src="https://e.com/t.jpg" srcset="https://e.com/t.jpg 300w, https://e.com/t2.jpg 600w" sizes="200px" width="200" alt="thumb">
        <img src="https://e.com/s.jpg" srcset="https://e.com/s.jpg 300w, https://e.com/s2.jpg 700w" sizes="(max-width: 900px) 300px, 400px" alt="small slots">
        """, base: nil)
        #expect(!out.contains("50vw"))
        #expect(!out.contains("450px"))
        #expect(out.contains("sizes=\"200px\""))
        #expect(out.contains("(max-width: 900px) 300px, 400px"))
    }

    @Test func aSrcsetThatMislabelsTheSrcFileGetsItsRealWidth() {
        let src = "https://e.com/a.jpg?w=942&h=628&crop=1"
        let out = ArticlePasses.cleanArticle("<img src=\"\(src)\" srcset=\"\(src) 1800w, \(src)&resize=300%2C200 300w\" alt=\"lead\">", base: nil)
        #expect(out.contains("h=628&amp;crop=1 942w"))
        #expect(!out.contains("1800w"))
    }

    // MARK: Copies

    @Test func aResponsivePairOfOnePictureShowsOnce() {
        let hero = "<img alt=\"Awardees\" src=\"https://e.com/hero.jpg?w=2400&amp;crop=1\" srcset=\"https://e.com/hero.jpg?w=376 376w, https://e.com/hero.jpg?w=2400 2400w\">"
        let out = ArticlePasses.cleanArticle("<p>\(hero)</p><p>\(hero)</p>\(p)", base: nil)
        #expect(out.components(separatedBy: "<img").count == 2)
        #expect(out.contains("The reader shows"))
    }

    @Test func variantsOfAChartWithTheSameDescriptionKeepTheWiderOne() {
        let alt = "A line chart that shows projected transmission-capacity growth through 2041"
        let out = ArticlePasses.cleanArticle("""
        <figure><p><img alt="\(alt)" src="https://g.axios.com/x-fallback.png" width="1200" height="928">
        <img alt="\(alt)" src="https://g.axios.com/x-apple.png" width="750" height="696"></p><figcaption>Chart: Axios</figcaption></figure>
        """, base: nil)
        #expect(out.contains("x-fallback.png"))
        #expect(!out.contains("x-apple.png"))
        #expect(out.contains("Chart: Axios"))
    }

    @Test func picturesWithTextBetweenThemAreNotCopies() {
        let img = "<img alt=\"Same words in the alt text of both\" src=\"https://e.com/a.jpg\" width=\"800\">"
        let out = ArticlePasses.cleanArticle("\(img)\(p)\(img)<img alt=\"Same words in the alt text of both\" src=\"https://e.com/b.jpg\" width=\"800\">", base: nil)
        #expect(out.components(separatedBy: "<img").count == 3)
    }

    @Test func differentShortAltsOnNeighboursAreKept() {
        let out = ArticlePasses.cleanArticle("""
        <p><img alt="Photo" src="https://e.com/1.jpg" width="800"></p><p><img alt="Photo" src="https://e.com/2.jpg" width="800"></p>\(p)
        """, base: nil)
        #expect(out.components(separatedBy: "<img").count == 3)
    }

    @Test func decorativeDividerPicturesGo() {
        let out = ArticlePasses.cleanArticle("""
        \(p)<figure><img src="https://g.io/2024/05/floating_linebreak_600px-1.png" alt="" width="600" height="157"></figure>
        <figure><img src="https://g.io/2024/05/chart.png" alt="" width="600" height="400"></figure>\(p)
        """, base: nil)
        #expect(!out.contains("linebreak"))
        #expect(out.contains("chart.png"))
    }

    // MARK: Buttons, asides

    @Test func aPictureInsideAZoomButtonStays() async throws {
        let zoom = """
        <figure><a role="button" aria-label="Zoomable image" aria-haspopup="dialog" href="https://e.com/big.jpg"><div><img alt="Protesters hold a sign" src="https://e.com/p.jpg" width="754" height="500"></div></a>
        <figcaption>Protest in Toronto</figcaption></figure>
        """
        let body = try await extract(article("\(p)\(zoom)\(p)"))
        #expect(body.contains("src=\"https://e.com/p.jpg\""))
        #expect(body.contains("Protest in Toronto"))
    }

    @Test func aButtonWithWordsIsStillRemoved() async throws {
        let body = try await extract(article("\(p)<button><img src=\"https://e.com/p.jpg\" width=\"754\">Expand</button>\(p)"))
        #expect(!body.contains("Expand"))
    }

    // MARK: Readability

    /// The real Readability: figures it would have discarded (needs WebKit; skipped like ExtractionWebKitTests).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1")) @MainActor
    func figuresSurviveReadabilityDespiteTheirClassesAndLinks() async throws {
        let html = """
        <!doctype html><html><head><title>Mars</title></head><body><article><h1>Mars</h1>
        \(p)
        <div class="hds-media hds-module"><div class="hds-media-wrapper"><figure class="hds-media-inner hds-cover-wrapper"><a href="https://e.com/nasa.jpg"><img src="https://e.com/nasa.jpg" width="2048" height="1582" alt="A rock slice"></a><figcaption>Slice of a meteorite. Credit: NASA</figcaption></figure></div></div>
        \(p)
        <div class="mol-img-group"><div class="mol-img"><img src="https://e.com/mail.jpg" width="634" height="423" class="blkBorder img-share" alt="Putin warns"></div><p class="imageCaption">Putin warns the West</p></div>
        \(p)
        <div class="captioned-image-container"><figure><a class="image-link" href="https://e.com/chart.jpeg"><div class="image2-inset"><img src="https://e.com/chart.jpeg" width="877" height="415" alt=""></div></a><figcaption class="image-caption"><span>Source: </span><a href="https://e.com/report.pdf">Ober et al. (2026)</a></figcaption></figure></div>
        \(p)
        <figure><a href="https://e.com/ign.webp"><img alt="" aria-hidden="true" role="presentation" src="https://e.com/ign.webp"></a><figcaption>Art by Miller</figcaption></figure>
        \(p)
        <aside class="post__aside"><figure><div><img width="604" height="604" src="https://e.com/portrait.webp" alt="Portrait of a guest"></div><figcaption>Shep Doeleman</figcaption></figure></aside>
        \(p)
        <figure class="image component"><div class="component-content"><div class="image-sharesheet"><div class="image-asset"><img src="https://e.com/apple.jpg" srcset="https://e.com/apple.jpg 2x" alt="A MacBook"></div></div></div></figure>
        \(p)
        </article></body></html>
        """
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: "https://e.com/story")
        let body = try #require(out.contentHtml)
        for name in ["nasa.jpg", "mail.jpg", "chart.jpeg", "ign.webp", "portrait.webp", "apple.jpg"] {
            #expect(body.contains(name), "\(name)")
        }
        // The caption's link is back a link, not a span.
        #expect(body.contains("href=\"https://e.com/report.pdf\""))
        #expect(!body.contains("data-od-href"))
    }

    @Test func advertisementsKeepTheirReasonToBeDropped() async throws {
        let ad = "<div class=\"ad-banner media\"><img src=\"https://e.com/ad.jpg\" width=\"728\" height=\"90\" alt=\"Sponsored\"></div>"
        let doc = try #require(ExtractionDOM.parseDocument(article("\(p)\(ad)\(p)"), baseURI: "https://e.com/"))
        ArticlePasses.shieldFigures(doc)
        #expect(ExtractionDOM.first(doc, "div")?.hasClass("ad-banner") == true)
    }
}
