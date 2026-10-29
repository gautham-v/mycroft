import Foundation
import Testing
@testable import OpenDispatchCore

/// Captions and styling the first rounds left (Blogger, The Athletic, VentureBeat, Cursor, Times Now, PCMag, Android
/// Authority, Vogue, Android Police, BBC, HuffPost, Cleveland.com, People, El País, the New York Post, and the lead
/// picture's caption on news sites).
@Suite("Extraction: captions and styling, second round")
struct ExtractionPolish2Tests {
    static let first = String(repeating: "The council met on Tuesday to settle the budget for the coming year. ", count: 4)
    static let second = String(repeating: "Residents asked about the bridge repairs and the late buses downtown. ", count: 4)
    var p1: String { "<p>\(Self.first)</p>" }
    var p2: String { "<p>\(Self.second)</p>" }

    func clean(_ html: String) -> String {
        ArticleSanitizer.sanitize(ArticlePasses.cleanArticle(html, base: "https://www.example.com/news/story"))
    }

    func prepared(_ html: String) -> String {
        DOM.withFragment("<div id=\"r\">\(html)</div>") { body -> String in
            let root = DOM.first(body, "#r")!
            ArticlePasses.preparePolish2(root)
            return DOM.innerHTML(root)
        } ?? ""
    }

    private typealias DOM = ExtractionDOM

    func extract(_ body: String, head: String = "", url: String = "https://www.example.com/news/story") async throws -> ExtractResult {
        let html = "<html><head><title>T</title>\(head)</head><body>\(body)</body></html>"
        return try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
    }

    // MARK: Before Readability

    @Test func reactTextSeparatorsGo() {
        // Cursor: "Principal Engineer<!-- -->, <!-- -->PGA America" became three paragraphs, one a lone comma.
        let out = prepared("<div><div>Michael Gyarmathy</div><div>Principal Engineer<!-- -->, <!-- -->PGA America</div></div>")
        #expect(!out.contains("<!--"))
        #expect(out.contains("Principal Engineer, PGA America"))
    }

    @Test func inlineBoldAndItalicBecomeTags() {
        // Blogger: the style attribute is all that made these a heading and a run-in.
        let out = prepared("<span style=\"font-weight: bold;\">Alternative Policies We Considered</span><br><span style=\"font-style: italic;\">Authoritative International Institutions.</span> We considered deferring.")
        #expect(out.contains("<strong>Alternative Policies We Considered</strong>"))
        #expect(out.contains("<em>Authoritative International Institutions.</em>"))
    }

    @Test func googleDocsNormalWeightWrapperIsNoBold() {
        let out = prepared("<b style=\"font-weight:normal;\" id=\"docs-internal-guid-1\"><p>Plain words in a paste.</p></b>")
        #expect(!out.contains("<b"))
        #expect(out.contains("Plain words in a paste."))
    }

    @Test func aStyledSpanAroundBlocksStaysPlain() {
        let out = prepared("<span style=\"font-weight:700\"><p>A whole section that happens to sit in a bold span.</p></span>")
        #expect(!out.contains("<strong>"))
    }

    @Test func ariaHiddenCaptionWithWordsIsShown() {
        // El País hides its visible caption from screen readers.
        let out = prepared("<figure><img src=\"https://e.com/a.jpg\"><figcaption aria-hidden=\"true\"><span>Tom Moore at his desk.</span></figcaption></figure>")
        #expect(!out.contains("aria-hidden"))
    }

    // MARK: Captions

    @Test func altTextLineUnderAPictureIsItsCaption() {
        // Times Now's cover image.
        let out = clean("<div><p><img src=\"https://e.com/cover.jpg\" alt=\"Security flaws in two apps (AI-generated)\"></p><p>Security flaws in two apps (AI-generated)</p></div>\(p1)")
        #expect(out.contains("<figure><img src=\"https://e.com/cover.jpg\""))
        #expect(out.contains("<figcaption>Security flaws in two apps (AI-generated)</figcaption>"))
        #expect(!out.contains("<p>Security flaws"))
    }

    @Test func smallLineUnderAPictureIsItsCaption() {
        // PCMag.
        let out = clean("\(p1)<p><img src=\"https://e.com/station.jpg\" alt=\"The station\"></p><p><small>The station is dense but portable (Credit: Michael Lydick)</small></p>\(p2)")
        #expect(out.contains("<figcaption>The station is dense but portable (Credit: Michael Lydick)</figcaption>"))
    }

    @Test func creditLinesUnderAPictureAreItsCaption() {
        // Android Authority's "Name / Outlet", Vogue's "Photo: Courtesy of …".
        let a = clean("<div><p><img src=\"https://e.com/ui.jpg\" alt=\"The interface\"></p><div><p>Brady Snyder / Android Authority</p></div></div>\(p1)")
        #expect(a.contains("<figcaption>Brady Snyder / Android Authority</figcaption>"))
        let b = clean("<div><div><p><span><img src=\"https://e.com/stage.png\" alt=\"A stage\"></span></p></div><div><p><span>Photo: Courtesy of Liz Phair</span></p></div></div>\(p1)")
        #expect(b.contains("<figcaption>Photo: Courtesy of Liz Phair</figcaption>"))
    }

    @Test func aSentenceAfterAPictureStaysText() {
        let out = clean("\(p1)<p><img src=\"https://e.com/chart.jpg\" alt=\"A chart\"></p><p>The numbers rose sharply in the second quarter.</p>\(p2)")
        #expect(!out.contains("<figcaption>"))
        #expect(out.contains("<p>The numbers rose sharply"))
    }

    @Test func aCreditBesideThePictureInAFigureBecomesItsCaption() {
        // BBC: the copyright span sits beside the image.
        let out = clean("<figure><p><span><img src=\"https://e.com/burnham.png\" alt=\"Burnham\"></span><span>Reuters</span></p></figure>\(p1)")
        #expect(out.contains("<figcaption>Reuters</figcaption>"))
    }

    @Test func aCreditAfterTheCaptionJoinsIt() {
        // HuffPost: the credit block follows the <figcaption>.
        let out = clean("<figure><div><p><img src=\"https://e.com/crash.jpg\"></p></div><div><figcaption>Cranes lift wrecked carriages.</figcaption><div><p><span>AP Photo/Manu Fernandez</span></p></div></div></figure>\(p1)")
        #expect(out.contains("Cranes lift wrecked carriages. AP Photo/Manu Fernandez</figcaption>"))
        #expect(!out.contains("<p><span>AP Photo"))
    }

    @Test func aDekAboveThePictureStaysOutOfTheCaption() {
        let out = clean("<figure><div><p>Dynasties are dead and parity is king.</p></div><p><img src=\"https://e.com/nba.jpg\"></p><figcaption>Getty Images/Ringer illustration</figcaption></figure>\(p1)")
        #expect(out.contains("<figcaption>Getty Images/Ringer illustration</figcaption>"))
    }

    @Test func aRepeatedCreditInTheCaptionGoes() {
        // Cleveland.com.
        let out = clean("<figure><img src=\"https://e.com/suv.jpg\"><figcaption><span>The recall applies to 13,330 SUVs. (Photo by Smith Collection/Gado/Getty Images) <span>Gado via Getty Images</span></span></figcaption></figure>\(p1)")
        #expect(out.contains("(Photo by Smith Collection/Gado/Getty Images)"))
        #expect(!out.contains("Gado via Getty Images"))
    }

    @Test func aSpaceBeforeTheCreditColonGoes() {
        let out = clean("<figure><img src=\"https://e.com/myers.jpg\"><figcaption><span>Mike Myers in May.</span> <span>Credit : Getty</span></figcaption></figure>\(p1)")
        #expect(out.contains("Credit: Getty"))
    }

    @Test func galleryCaptionBlocksRunAsOneCaptionWithTheCreditLast() {
        // Vogue: credit, counter, caption, each a block.
        let out = clean("<figure><div><p><span><img src=\"https://e.com/gala.jpg\"></span></p></div><figcaption><div><p>Stefanie Keenan/Getty Images</p> <p><span>1/35</span></p> <div><p>Charlize Theron</p></div></div></figcaption></figure>\(p1)")
        #expect(out.contains("<figcaption>Charlize Theron Stefanie Keenan/Getty Images</figcaption>"))
        #expect(!out.contains("1/35"))
    }

    @Test func theSamePictureAndCaptionTwiceShowsOnce() {
        let fig = "<figure><img src=\"https://e.com/art.jpg\"><figcaption>Photo-Illustration: Vulture; Photos: Getty</figcaption></figure>"
        let out = clean("\(fig)<div>\(fig)</div>\(p1)")
        #expect(out.components(separatedBy: "art.jpg").count == 2)
    }

    @Test func mojibakeInACaptionIsRepaired() {
        let out = clean("<figure><img src=\"https://e.com/gg.jpg\"><figcaption>A scene from the show. Â©Warner Bros and itâ€™s fine</figcaption></figure>\(p1)")
        #expect(out.contains("©Warner Bros and it’s fine"))
    }

    // MARK: Lists, headings, tables

    @Test func aListOfPicturesIsARunOfPictures() {
        // Android Police's gallery and Vogue's slides, with an empty slide.
        let out = clean("\(p1)<ul><li><p><img src=\"https://e.com/1.jpg\"></p></li><li><figure><img src=\"https://e.com/2.jpg\"><figcaption>Second shot</figcaption></figure></li><li></li></ul>\(p2)")
        #expect(!out.contains("<ul>"))
        #expect(!out.contains("<li>"))
        #expect(out.contains("1.jpg") && out.contains("2.jpg") && out.contains("Second shot"))
    }

    @Test func aListOfProductsWithLinksStaysAList() {
        let out = clean("\(p1)<ul><li><img src=\"https://e.com/a.jpg\"><a href=\"https://shop.e.com/a\">Buy the pan</a></li><li><img src=\"https://e.com/b.jpg\"><a href=\"https://shop.e.com/b\">Buy the pot</a></li></ul>\(p2)")
        #expect(out.contains("<ul>"))
    }

    @Test func bulletLinesBecomeAList() {
        // The Athletic.
        let out = clean("<p>In 2019:</p><p>• The Steelers traded a first for a defensive back<br>\n• The Rams traded two firsts for a cornerback</p>\(p1)")
        #expect(out.contains("<ul><li>The Steelers traded a first for a defensive back</li><li>The Rams traded two firsts for a cornerback</li></ul>"))
        #expect(!out.contains("•"))
    }

    @Test func oneBulletParagraphPerItemJoinsOneList() {
        let out = clean("<p>• Grok Bot: an assistant for chats</p>\n<p>• Dot: a companion that remembers</p>\(p1)")
        #expect(out.contains("<ul><li>Grok Bot: an assistant for chats</li><li>Dot: a companion that remembers</li></ul>"))
    }

    @Test func aMidSentenceBulletIsNotAList() {
        let out = clean("<p>Simon Harmer had the centurion nicking behind • AFP/Getty Images and more words follow.</p>\(p1)")
        #expect(!out.contains("<ul>"))
    }

    @Test func aBoldHeadingWithAParenthesisIsAHeading() {
        // The Athletic's "Defense (opponent)" beside "Offense".
        let out = clean("<p><strong>Offense</strong></p><p><strong>EFG%:</strong> 1. Lakers</p><p><strong>Defense (opponent)</strong></p><p><strong>EFG%:</strong> 1. Raptors</p>")
        #expect(out.contains("<h3>Offense</h3>"))
        #expect(out.contains("<h3>Defense (opponent)</h3>"))
    }

    @Test func aBoldFirstRowIsTheHeaderRow() {
        // VentureBeat's pricing table.
        let out = clean("\(p1)<table><tbody><tr><td><p><b>Model</b></p></td><td><p><b>Input ($/1M)</b></p></td></tr><tr><td><p>Muse Spark</p></td><td><p>$0.10</p></td></tr></tbody></table>")
        #expect(out.contains("<thead><tr><th>Model</th><th>Input ($/1M)</th></tr></thead>"))
        #expect(out.contains("<td>Muse Spark</td><td>$0.10</td>"))
    }

    @Test func aTableWithAPlainFirstRowKeepsIt() {
        let out = clean("\(p1)<table><tbody><tr><td><b>Model</b></td><td>Input</td></tr><tr><td>Muse</td><td>$0.10</td></tr></tbody></table>")
        #expect(!out.contains("<th>"))
    }

    // MARK: Lead caption

    @Test func theLeadsCaptionLeadsTheBody() async throws {
        // The hero sits in the page header, outside the article; the reader would draw it bare.
        let head = "<meta property=\"og:image\" content=\"https://cdn.e.com/photos/senate-race-1200.jpg\">"
        let body = "<header><h1>T</h1><figure><img src=\"https://cdn.e.com/photos/senate-race-1200.jpg\" alt=\"Candidates\"><figcaption>Texas' Senate candidates at a debate [Reuters]</figcaption></figure></header><article>\(p1)\(p2)</article>"
        let out = try await extract(body, head: head)
        let html = try #require(out.contentHtml)
        #expect(html.hasPrefix("<figure><img src=\"https://cdn.e.com/photos/senate-race-1200.jpg\""))
        #expect(html.contains("<figcaption>Texas' Senate candidates at a debate [Reuters]</figcaption>"))
        #expect(LeadImage.contentHasHero(html, hero: try #require(out.leadImage)))
    }

    @Test func aCreditLineForTheLeadMovesUnderIt() async throws {
        // Vice ends the story with the featured image's credit.
        let head = "<meta property=\"og:image\" content=\"https://cdn.e.com/wp/bride.jpg\">"
        let body = "<header><figure><img src=\"https://cdn.e.com/wp/bride.jpg\"><figcaption>Photo by FilmPublicityArchive/United Archives via Getty Images</figcaption></figure></header><article>\(p1)\(p2)<p><em>Photo by FilmPublicityArchive/United Archives via Getty Images</em></p></article>"
        let html = try #require(try await extract(body, head: head).contentHtml)
        #expect(html.hasPrefix("<figure>"))
        #expect(html.components(separatedBy: "FilmPublicityArchive").count == 2)
    }

    @Test func anotherPictureIsNotTheLeadsCaption() async throws {
        let head = "<meta property=\"og:image\" content=\"https://cdn.e.com/photos/hero.jpg\">"
        let body = "<header><figure><img src=\"https://cdn.e.com/photos/other-shot.jpg\"><figcaption>A different photo entirely</figcaption></figure></header><article>\(p1)\(p2)</article>"
        let html = try #require(try await extract(body, head: head).contentHtml)
        #expect(!html.contains("A different photo entirely"))
    }

    @Test func aRepeatedCreditTailGoes() {
        #expect(ArticlePasses.dropRepeatedTail("Lina Attalah in 2017. Photograph: Roger Anis/AP Photograph: Roger Anis/AP") == "Lina Attalah in 2017. Photograph: Roger Anis/AP")
        #expect(ArticlePasses.dropRepeatedTail("New York, New York") == "New York, New York")
    }
}
