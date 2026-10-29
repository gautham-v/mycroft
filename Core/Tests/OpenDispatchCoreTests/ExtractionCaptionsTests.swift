import Foundation
import Testing
@testable import OpenDispatchCore

/// Captions and credits found by comparing the reader with the original pages (Krebs, Fox News, Mother Jones, Engadget,
/// Eater, Foreign Policy, CBC, CNN, Wired, Aeon, DW, IEEE Spectrum and others).
@Suite("Extraction: captions")
struct ExtractionCaptionsTests {
    typealias DOM = ExtractionDOM

    /// Run the page-side pass on a fragment and return what is left.
    func figures(_ html: String) -> String {
        DOM.withFragment("<div id=\"__root\">\(html)</div>") { body -> String in
            guard let root = DOM.first(body, "#__root") else { return "" }
            ArticlePasses.captionFigures(root)
            return DOM.innerHTML(root)
        } ?? ""
    }

    func figureCount(_ s: String) -> Int { s.components(separatedBy: "<figure>").count - 1 }

    @Test func wordPressCaptionTextBecomesAFigcaption() {
        let out = figures("""
        <p>Before.</p><div id="attachment_1" class="wp-caption alignnone"><img src="https://e.com/a.png" alt="">\
        <p id="caption-attachment-1" class="wp-caption-text">Image: Shutterstock.com, Sashkin.</p></div><p>After.</p>
        """)
        #expect(out.contains("<figure><img src=\"https://e.com/a.png\" alt=\"\" /><figcaption>Image: Shutterstock.com, Sashkin.</figcaption></figure>"))
        #expect(!out.contains("<p id=\"caption-attachment-1\""))
        #expect(out.contains("<p>After.</p>"))
    }

    @Test func aCaptionAndItsCreditInSeparateSpansAreSeparatedByASpace() {
        let out = figures("""
        <div class="wp-caption"><img src="https://e.com/a.jpg">\
        <p class="wp-caption-text"><span class="media-caption">Charli XCX performs onstage in Los Angeles, California.</span>\
        <span class="media-credit">Katie Flores/WWD/Getty</span></p></div>
        """)
        #expect(out.contains("California. Katie Flores/WWD/Getty</figcaption>"))
    }

    @Test func aCaptionBlockBesideThePicturesWrapperIsItsCaption() {
        // Fox News: the picture's wrapper, then div.info > div.caption.
        let out = figures("""
        <div class="image-ct"><div class="m"><picture><source srcset="https://e.com/s.jpg"><img src="https://e.com/a.jpg" alt="Stone Romberg"></picture></div> \
        <div class="info"><div class="caption"><p><span>Stone Romberg pictured with his daughter.</span> <span>(Facebook/La Dolce Vita)</span></p></div></div></div>
        """)
        #expect(figureCount(out) == 1)
        #expect(out.contains("<figcaption>Stone Romberg pictured with his daughter. (Facebook/La Dolce Vita)</figcaption>"))
        #expect(!out.contains("class=\"info\""))
    }

    @Test func aCreditCiteInACaptionDivIsACaption() {
        // Eater: the image nested in two divs, then div.duet--media--caption > cite.
        let out = figures("""
        <div><div><div><img src="https://e.com/b.jpg"></div></div><div class="duet--media--caption _1l5wi2a1"><cite class="x">Monica Burton</cite></div></div>
        """)
        #expect(out.contains("<figcaption>Monica Burton</figcaption>"))
    }

    @Test func aCreditSpanAfterAPictureIsACaption() {
        // Engadget: <picture> then span.gallery-image-credit.
        let out = figures("""
        <div><picture><img src="https://e.com/c.jpg" alt="Cards"></picture> <span class="gallery-image-credit">celenk88/Shutterstock</span></div>
        """)
        #expect(out.contains("<figcaption>celenk88/Shutterstock</figcaption>"))
    }

    @Test func aCaptionAfterAFigureOfJustThePictureJoinsIt() {
        // CBC: <figure> of the picture, then p.imageCaption.
        let out = figures("""
        <div><div class="html-image"><figure><picture><img src="https://e.com/d.jpg"></picture></figure>\
        <p class="imageCaption-oOSXz">Gebala's reaction.<!-- --> <!-- -->(David Gebala/Facebook)</p></div></div>
        """)
        #expect(figureCount(out) == 1)
        #expect(out.contains("<figcaption>Gebala's reaction. (David Gebala/Facebook)</figcaption></figure>"))
    }

    @Test func aCaptionBlockInsideAFigureWithoutAFigcaptionBecomesOne() {
        // Wired and Pitchfork: figure > div.caption > span.caption__credit.
        let out = figures("""
        <figure><div><img src="https://e.com/e.jpg"></div><div class="CaptionWrapper caption"><span class="CaptionCredit caption__credit">Photograph: Courtesy of Apple</span></div></figure>
        """)
        #expect(out.contains("<figcaption>Photograph: Courtesy of Apple</figcaption></figure>"))
        #expect(!out.contains("CaptionWrapper"))
    }

    @Test func aCaptionAndCreditElsewhereInAMetadataBlockAreOneCaption() {
        // CNN: image container, then a metadata wrapper with div.caption and figcaption.credit; an empty caption goes.
        let out = figures("""
        <div class="image"><div class="image__container"><picture><img src="https://e.com/f.jpg"></picture></div>\
        <div class="image__metadata-wrapper"><div class="image__metadata-container"><div class="image__metadata">\
        <div itemprop="caption" class="image__caption"><span></span></div>\
        <figcaption class="image__credit">Courtesy Wendy Auger</figcaption></div></div></div></div>
        """)
        #expect(out.contains("<figcaption>Courtesy Wendy Auger</figcaption>"))
        let two = figures("""
        <div class="image"><div class="image__container"><picture><img src="https://e.com/g.jpg"></picture></div>\
        <div class="image__metadata-wrapper"><div class="image__metadata">\
        <div itemprop="caption" class="image__caption"><span>The recall letter.</span></div>\
        <figcaption class="image__credit">Courtesy Wendy Auger</figcaption></div></div></div>
        """)
        #expect(two.contains("<figcaption>The recall letter. Courtesy Wendy Auger</figcaption>"))
    }

    @Test func hiddenAltTextFigcaptionsAndEmptyOnesGo() {
        // Foreign Policy keeps the alt text in a figcaption it hides; Aeon has an empty one.
        let out = figures("""
        <div class="wp-caption"><span><img src="https://e.com/h.jpg"></span>\
        <figcaption style="height:0;opacity:0;">A crowd marches along a street.</figcaption>\
        <p class="wp-caption-text">A protester takes part in a march in New York. <span class="attribution">Jerome Gilles/NurPhoto</span></p></div>\
        <figure><img src="https://e.com/i.jpg"><figcaption></figcaption></figure>
        """)
        #expect(!out.contains("A crowd marches"))
        #expect(out.contains("<figcaption>A protester takes part in a march in New York. Jerome Gilles/NurPhoto</figcaption>"))
        #expect(!out.contains("<figcaption></figcaption>"))
    }

    @Test func aRepeatedCreditAndAShowHideControlLeaveOneCaption() {
        let out = figures("""
        <div class="wp-caption"><img src="https://e.com/j.jpg"><div class="caption"><span>Defense chiefs meet.</span> \
        <span class="credit">EPA via AP</span><button>toggle caption</button><span class="credit">EPA via AP</span></div></div>
        """)
        #expect(out.contains("<figcaption>Defense chiefs meet. EPA via AP</figcaption>"))
    }

    @Test func captionWordsNotNextToAPictureStayText() {
        let html = "<div class=\"credits\"><p>Directed by Someone.</p></div><p>Story.</p><div class=\"caption\">Table 1</div><p>More.</p>"
        let out = figures(html)
        #expect(figureCount(out) == 0)
        #expect(out.contains("Directed by Someone."))
        #expect(out.contains("Table 1"))
    }

    @Test func aFigureThatHasACaptionIsLeftAlone() {
        let html = "<figure><img src=\"https://e.com/k.jpg\"><figcaption class=\"caption\">Real caption.</figcaption></figure>"
        let out = figures(html)
        #expect(figureCount(out) == 1)
        #expect(out.contains("<figcaption class=\"caption\">Real caption.</figcaption>"))
    }

    @Test func aResponsiveTwinAndANoscriptCopyAreOnePicture() {
        // Eater draws one photo twice (desktop and mobile); Reason keeps a <noscript> copy of its lazy image.
        let twins = figures("""
        <div><div class="a"><img src="https://e.com/l.jpg?w=2400" alt="Clams"></div><div class="b"><img src="https://e.com/l.jpg?w=750" alt="Clams"></div>\
        <div class="media-caption"><cite>Monica Burton</cite></div></div>
        """)
        #expect(figureCount(twins) == 1)
        #expect(twins.contains("<figcaption>Monica Burton</figcaption>"))
        let lazy = figures("""
        <div class="img-wrap"><picture><img src="https://e.com/m.jpg" alt="A phone with the Kalshi logo in front of a court"><noscript><img src="https://e.com/m2.jpg" alt="Phone | Illustration"></noscript></picture></div>\
        <div class=" photo-credit clearfix"><span> (Illustration: Sipa USA) </span></div>
        """)
        #expect(lazy.contains("<figcaption>(Illustration: Sipa USA)</figcaption>"))
    }

    @Test func captionPartsGetASpaceAndAFigureOfOnlyACaptionGoes() {
        let out = ArticlePasses.cleanArticle("""
        <figure><img src="https://e.com/n.jpg" width="800" height="400"><figcaption>The Likud party has complained<small>Image: Katrine Houmoller/MEI</small></figcaption></figure>
        <figure><figcaption>Supercharged by the all-new M6 chip.</figcaption></figure>
        <figure><img src="https://e.com/o.jpg" width="800" height="400"><figcaption><span>The recall applies to SUVs. (Photo by Smith/Getty Images)<span>Gado via Getty Images</span></span></figcaption></figure>
        """, base: nil)
        #expect(out.contains("complained <small>Image: Katrine Houmoller/MEI</small>"))
        #expect(out.contains("Getty Images) <span>Gado via Getty Images</span>"))
        #expect(!out.contains("Supercharged"))
        #expect(figureCount(out) == 2)
    }

    @Test func anAffiliateNoteUnderAPictureIsNotItsCaption() {
        let out = ArticlePasses.cleanArticle("""
        <p><img src="https://e.com/p.jpg" width="800" height="400"><em><small>Note: MacRumors is an affiliate partner with some of these vendors. \
        When you click a link and make a purchase, we may receive a small payment, which helps us keep the site running.</small></em></p>
        <p>Although only a $9 discount, this is still the biggest deal we've seen.</p>
        """, base: nil)
        #expect(!out.contains("affiliate"))
        #expect(out.contains("<img"))
        #expect(out.contains("biggest deal"))
    }

    @Test func photosSideBySideShareTheCaptionUnderThem() {
        // Daily Mail: left and right photos in one splitter, then p.imageCaption.
        let out = figures("""
        <div class="artSplitter"><div class="splitLeft"><div class="mol-img"><div class="image-wrap"><img src="https://e.com/l.jpg"></div></div></div>\
        <div class="splitRight"><div class="mol-img"><div class="image-wrap"><img src="https://e.com/r.jpg"></div></div></div>\
        <p class="imageCaption">Jackie Apostel (L) and Kim Turnbull (R) enjoyed a night out</p></div>
        """)
        #expect(figureCount(out) == 1)
        #expect(out.contains("l.jpg"))
        #expect(out.contains("r.jpg"))
        #expect(out.contains("<figcaption>Jackie Apostel (L) and Kim Turnbull (R) enjoyed a night out</figcaption>"))
    }

    @Test func abbreviatedCaptionClassesCount() {
        // Times of India: div.img_cptn after the picture's wrappers.
        let out = figures("""
        <div><div><div><img src="https://e.com/q.jpg" alt="Poll"></div></div><div class="Ta7d_ img_cptn"><span>File photo: Election Commission of India</span></div></div>
        """)
        #expect(out.contains("<figcaption>File photo: Election Commission of India</figcaption>"))
    }

    @Test func aPageWithCaptionsKeepsThemThroughExtraction() async throws {
        let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
        let html = """
        <html><head><title>Flaw</title></head><body><article><h1>Flaw</h1><p>\(para)</p>
        <div id="attachment_1" class="wp-caption alignnone"><img src="https://e.com/a.png" alt="">\
        <p id="caption-attachment-1" class="wp-caption-text">Image: Shutterstock.com, Sashkin.</p></div><p>\(para)</p></article></body></html>
        """
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: "https://e.com/story")
        let body = try #require(out.contentHtml)
        let flat = body.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "  ", with: "").replacingOccurrences(of: "<figcaption> ", with: "<figcaption>")
        #expect(flat.contains("<figcaption>Image: Shutterstock.com, Sashkin.</figcaption>"))
        #expect(!flat.contains("<p>Image: Shutterstock.com"))
    }
}
