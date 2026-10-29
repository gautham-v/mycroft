import Foundation
import Testing
@testable import OpenDispatchCore

/// Structure the reader's stylesheet needs, found by comparing articles with their pages: summary cards, pull quotes,
/// rules, lists, spaces, code and links.
@Suite("Extraction: styling")
struct ExtractionStylingTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func extract(_ body: String, url: String = "https://e.com/story") async throws -> String {
        let html = "<html><head><title>T</title></head><body><article>\(body)</article></body></html>"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        // The serializer indents block tags; compare without that.
        return try #require(out.contentHtml).replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
    }

    @Test func summaryBoxKeepsItsCard() async throws {
        let out = try await extract("\(p)<div><h2>In short</h2><p>One.</p><p>Two.</p></div>\(p)")
        #expect(out.contains("<div class=\"x-callout\"><h2>In short</h2>"))
    }

    @Test func labelAboveAListIsACard() async throws {
        let out = try await extract("\(p)<p>TL;DR</p><ul><li>One</li><li>Two</li></ul>\(p)")
        #expect(out.contains("<div class=\"x-callout\"><p>TL;DR</p>"))
    }

    @Test func didYouKnowAndNoteQuotesAreCards() async throws {
        let out = try await extract("\(p)<div><p>Did you know? Coined words</p><p>Details.</p></div><blockquote><p> Note</p><p>Careful.</p></blockquote>\(p)")
        #expect(out.components(separatedBy: "x-callout").count == 3)
        #expect(out.contains("<p>Note</p>"))
    }

    @Test func ordinaryHeadingSectionIsNotACard() async throws {
        let out = try await extract("\(p)<div><h2>Background</h2><p>One.</p><p>Two.</p></div>\(p)")
        #expect(!out.contains("x-callout"))
    }

    @Test func pullQuoteTakesItsAttribution() async throws {
        let out = try await extract("\(p)<div><blockquote>\"I blocked them and I reported it as phishing,\"</blockquote><p><span>  Ms Rojas-Valdez said.</span></p></div>\(p)")
        #expect(out.contains("Ms Rojas-Valdez said."))
        #expect(!out.contains("</blockquote><p>"))
    }

    @Test func attributionAfterAQuoteWithoutACommaJoinsToo() async throws {
        let out = try await extract("\(p)<div><blockquote>\"These are scams\"</blockquote><p><span>she said.</span></p></div>\(p)")
        #expect(out.contains("she said.") && !out.contains("</blockquote><div") && !out.contains("</blockquote><p>"))
        #expect(out.range(of: "she said.")!.lowerBound < out.range(of: "</blockquote>")!.lowerBound)
        let whole = try await extract("\(p)<blockquote><p>This is a full sentence of someone's.</p></blockquote><p>He said.</p>\(p)")
        #expect(whole.contains("</blockquote><p>He said.</p>"))
    }

    @Test func pullQuoteRepeatingTheTextGoes() async throws {
        let line = "Voters were more concerned about spending from AI companies than from crypto companies."
        let out = try await extract("\(p)<p>Polls found it. \(line) That mattered.</p><figure><blockquote><p>\(line)</p></blockquote></figure>\(p)")
        #expect(!out.contains("<blockquote"))
        #expect(!out.contains("<figure"))
        // A real quotation of the article's own words stays.
        let other = try await extract("\(p)<p>Earlier I said: \(line)</p><blockquote><p>\(line)</p></blockquote>\(p)")
        #expect(other.contains("<blockquote"))
    }

    @Test func rulesBeforePicturesAndAtTheEndGo() async throws {
        let out = try await extract("\(p)<hr><div><p><span><img src=\"https://e.com/a.jpg\" alt=\"a\"></span></p></div>\(p)<hr>\(p)<hr><hr>\(p)<hr>")
        #expect(out.components(separatedBy: "<hr").count == 4)
    }

    @Test func emptySpanDoesNotSplitAList() async throws {
        let out = try await extract("\(p)<ul><li>One</li></ul><span></span><ul><li>Two</li></ul>\(p)")
        #expect(out.components(separatedBy: "<ul>").count == 2)
        #expect(!out.contains("<span></span>"))
    }

    @Test func leadingNonBreakingSpaceIsTrimmed() async throws {
        let out = try await extract("\(p)<p>&nbsp;The Brewers were nobody's pick.</p>\(p)")
        #expect(out.contains("<p>The Brewers were nobody's pick.</p>"))
    }

    @Test func blankLinkKeepsItsSpace() async throws {
        let out = try await extract("\(p)<p>“One of the dreams,” says<a href=\"https://e.com/x\"> </a><a href=\"https://e.com/y\">Anubhav Datta</a>, a professor.</p>\(p)")
        #expect(out.contains("says <a"))
    }

    @Test func phoneLinksKeepTheirHref() async throws {
        let out = try await extract("\(p)<ul><li><a href=\"tel:+34935744222\">643 37 40 05</a></li></ul>\(p)")
        #expect(out.contains("href=\"tel:+34935744222\""))
    }

    @Test func linkButtonsAreSeparateLines() async throws {
        let out = try await extract("\(p)<div><a href=\"https://e.com/a\"><span>Download weights</span></a><a href=\"https://e.com/b\"><span>Try in Playground</span></a></div>\(p)")
        #expect(out.contains("</a><br /><a"))
        #expect(out.contains("<p><a"))
    }

    @Test func linkStartingASentenceGetsASpace() async throws {
        let out = try await extract("\(p)<ul><li>Owners describe breakdowns.<a href=\"https://e.com/a\">See which score best</a></li></ul>\(p)")
        #expect(out.contains("breakdowns. <a"))
    }

    @Test func commandBulletsBecomeCodeBlocks() async throws {
        let out = try await extract("\(p)<ol><li><p>Back it up:</p><ul><li><p> <code>[ -e /etc/ssl/cert.pem.orig ] || sudo cp -p /etc/ssl/cert.pem /etc/ssl/cert.pem.orig</code></p></li></ul></li></ol>\(p)")
        #expect(out.contains("<pre><code>[ -e /etc/ssl/cert.pem.orig ]"))
        let short = try await extract("\(p)<ul><li><code>foo</code></li><li><code>bar</code></li></ul>\(p)")
        #expect(!short.contains("<pre"))
    }

    @Test func codeLinesInsideCodeBecomeLines() async throws {
        let line = { (n: Int, t: String) in "<div class=\"ec-line\"><div class=\"gutter\"><div class=\"ln\">\(n)</div></div><div class=\"code\"><span>\(t)</span></div></div>" }
        let out = try await extract("\(p)<pre><code>\(line(1, "static void f()"))\(line(2, "{"))\(line(3, "}"))</code></pre>\(p)")
        #expect(out.contains("<pre><code>static void f()\n{\n}</code></pre>"))
        let one = try await extract("\(p)<pre><code><div><p><span>SHA-256(x)</span></p></div></code></pre>\(p)")
        #expect(one.contains("<pre><code>SHA-256(x)</code></pre>"))
    }

    @Test func numberBesideItsHeadingJoinsIt() async throws {
        let out = try await extract("\(p)<p><span>1.</span></p><h3>What's best?</h3>\(p)")
        #expect(out.contains("<h3>1. What's best?</h3>"))
    }

    @Test func orphanedPunctuationAfterAButtonGoes() async throws {
        let out = try await extract("\(p)<p>Remained active for longer. <span></span>, and see <a href=\"https://e.com/r\">the report</a>.</p>\(p)")
        #expect(out.contains("longer, and see"))
    }

    @Test func controlCharactersAndEscapedAmpersands() async throws {
        let out = try await extract("\(p)<figure><img src=\"https://e.com/a.jpg?quality=50u0026strip=all\" alt=\"\"><figcaption>Sweeney\u{92}s costumes</figcaption></figure>\(p)")
        #expect(out.contains("quality=50&amp;strip=all"))
        #expect(out.contains("Sweeney’s costumes"))
    }

    @Test func footnoteChipBecomesASuperscript() async throws {
        let out = try await extract("\(p)<p>The valley reaction.<span class=\"foot-ref\" data-footnote=\"a\">1</span> Even so.</p>\(p)")
        #expect(out.contains("<sup>1</sup>"))
    }

    @Test func deadPageAnchorIsPlainText() async throws {
        let out = try await extract("\(p)<p>Path: <a href=\"#missing-id\">AppData\\protocols.json</a> and <a href=\"#here\">see</a>.</p><h2 id=\"here\">Here</h2>\(p)")
        #expect(!out.contains("missing-id"))
        #expect(out.contains("AppData\\protocols.json"))
        // A link to an anchor that is there stays in the page (`#here`, with the id kept), not the absolute article URL.
        #expect(out.contains("href=\"#here\"") && out.contains("id=\"here\""))
    }

    @Test func emptyCanvasFigureGoes() async throws {
        let out = try await extract("\(p)<figure><canvas role=\"img\" aria-label=\"scales\"></canvas></figure>\(p)")
        #expect(!out.contains("<figure"))
    }
}
