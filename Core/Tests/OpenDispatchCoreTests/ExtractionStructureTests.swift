import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Content and structure lost on blogs and platforms (Blogger, Ghost, The New Yorker's cartoon, Stack Overflow's
/// blog, Ghostty's notes, Eater's map, SB Nation's picks, France 24).
@Suite("Extraction: content platforms")
struct ExtractionStructureTests {
    typealias DOM = ExtractionDOM
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func parse(_ html: String) throws -> Document {
        try #require(DOM.parseDocument(html, baseURI: "https://e.com/story"))
    }

    // MARK: Blogger

    @Test func aPostInAScriptTemplateReplacesItsScriptAndNoscriptCopy() throws {
        let post = "<span>Posted by A</span><br /><br />\(Self.para)<br /><br />\(Self.para)"
        let doc = try parse("<html><body><div class='post-content'><script type='text/template'>\(post)</script><noscript>\(post)</noscript></div></body></html>")
        ArticlePasses.unpackTemplates(doc)
        let box = try #require(DOM.first(doc, ".post-content"))
        #expect(DOM.text(box).contains("The reader shows the whole story"))
        #expect(DOM.first(doc, "script") == nil)
        #expect(DOM.first(doc, "noscript") == nil)
        #expect(DOM.text(box).components(separatedBy: "Posted by A").count == 2)
    }

    @Test func pageTemplatesAndShortOnesStay() throws {
        let doc = try parse("<html><body><script type='text/template'><li>{{ name }} \(Self.para)</li></script><script type='text/template'><b>short</b></script></body></html>")
        ArticlePasses.unpackTemplates(doc)
        #expect(DOM.select(doc, "script").count == 2)
    }

    // MARK: Ghost

    @Test func anElementListedTwiceInItsClassIsNotMergedIntoItself() throws {
        let doc = try parse("<html><body><article class='post post tag-x'><div class='content gh-content'>\(p)\(p)</div></article></body></html>")
        ArticlePasses.mergeSplitContainers(doc)
        #expect(DOM.first(doc, "article") != nil)
        #expect(DOM.proseLen(doc) >= 2 * Self.para.count - 10)
    }

    // MARK: France 24

    @Test func aSummaryFoldedBehindReadMoreIsRevealed() throws {
        let doc = try parse("""
        <html><body><div class="box"><div class="content" aria-hidden="true">\(p)</div>
        <button><span>Read more</span><span>Read less</span></button></div>
        <div class="deco" aria-hidden="true">\(p)</div></body></html>
        """)
        ArticlePasses.revealCollapsedText(doc)
        #expect(DOM.first(doc, ".content")?.hasAttr("aria-hidden") == false)
        // No button beside it: still hidden on purpose.
        #expect(DOM.first(doc, ".deco")?.hasAttr("aria-hidden") == true)
    }

    @Test func breadcrumbTrailsGo() throws {
        let doc = try parse("""
        <html><body><nav class="m-breadcrumb"><ol><li><a href="/">Home</a></li><li><a href="/a">Americas</a></li></ol></nav>
        <ul aria-label="Breadcrumb"><li><a href="/">Home</a></li></ul><ol class="steps"><li>One</li></ol></body></html>
        """)
        ArticlePasses.removeBreadcrumbs(doc)
        #expect(DOM.first(doc, "nav") == nil)
        #expect(DOM.select(doc, "ul").isEmpty)
        #expect(DOM.select(doc, "ol.steps").count == 1)
    }

    // MARK: Headings

    @Test func aHeadingKeepsItselfOutOfReadabilitysUnlikelyList() throws {
        let doc = try parse("""
        <html><body><article><h2 class="header" id="h2-ab12"><a title="Permalink" href="#h2-ab12" aria-hidden="true"></a><span><strong>Governance ends</strong></span></h2>
        <h3 class="related-header">Related</h3></article></body></html>
        """)
        ArticlePasses.keepHeadings(doc)
        #expect(DOM.first(doc, "h2").map { DOM.classTokens($0).isEmpty } == true)
        #expect(DOM.first(doc, "h2 a") == nil)
        // "related" is junk on its own.
        #expect(DOM.first(doc, "h3").map { DOM.classTokens($0) } == ["related-header"])
    }

    @Test func aBlockHoldingOnlyAHeadingAndAnIconGivesWayToTheHeading() throws {
        let doc = try parse("""
        <html><body><article><div class="card"><div class="JumplinkHeader-x__jumplinkHeader" id="security"><div class="row"><h2>Security</h2><a href="#security"><svg viewBox="0 0 8 8"></svg></a></div></div>
        \(p)<div class="name"><h2>Rooq</h2><span><button aria-label="Save"></button></span></div>\(p)</div>
        <div class="sidebar"><h2>Related</h2></div><div class="x"><h2>Rooq two</h2><img src="a.jpg"></div>
        <div class="meta"><h2>Card title</h2></div><div class="card-meta"><ul><li>2 days ago</li></ul></div></article></body></html>
        """)
        ArticlePasses.keepHeadings(doc)
        #expect(DOM.first(doc, "div.row") == nil && DOM.first(doc, ".JumplinkHeader-x__jumplinkHeader") == nil)
        #expect(DOM.first(doc, ".name") == nil)
        #expect(DOM.select(doc, ".card > h2").map { DOM.text($0) } == ["Security", "Rooq"])
        #expect(DOM.first(doc, ".sidebar > h2") != nil)
        #expect(DOM.first(doc, ".x > h2") != nil)
        // A card's title is followed by the card, not by text.
        #expect(DOM.first(doc, ".meta > h2") != nil)
    }

    @Test func aTablesColumnHeadingsAreNotEmptySections() {
        let html = "<table><thead><tr><th><h3>Week 8</h3></th><th><h3>Mookie</h3></th><th><h3>James</h3></th></tr></thead><tbody><tr><td>Packers</td><td>Packers</td><td>Jags</td></tr></tbody></table>\(p)"
        let out = ArticlePasses.cleanArticle(html, base: "https://e.com/")
        #expect(out.contains("Week 8") && out.contains("Mookie") && out.contains("James"))
    }

    // MARK: New Yorker

    static let cartoon = """
    <html><head><title>Daily Cartoon</title><meta property="og:title" content="Daily Cartoon"></head><body>
    <header><nav><a href="/">Home</a></nav></header><main><article><header><h1>Daily Cartoon</h1></header>
    <figure><div><a href="https://e.com/cartoon/a1"><picture><img alt="A cartoon" srcset="https://m.e.com/cartoons/a/w_640,c_limit/A62339.jpg 640w" src="https://m.e.com/cartoons/a/w_1600,c_limit/A62339.jpg"></picture></a>
    <div class="caption"><span>Cartoon by Alex Fraga</span></div></div></figure></article></main>
    <footer><ul><li><a href="/about">About</a></li><li><a href="/careers">Careers</a></li></ul><p>(c) 2026 Conde Nast. All rights reserved. Use of this site constitutes acceptance of our User Agreement and Privacy Policy and Cookie Statement.</p></footer></body></html>
    """

    @Test func aPageThatIsOnePictureYieldsItsFigure() throws {
        let doc = try parse(Self.cartoon)
        let figures = try #require(ArticlePasses.pictureStory(doc))
        #expect(figures.contains("A62339.jpg") && figures.contains("Cartoon by Alex Fraga"))
        #expect(ArticlePasses.containsPicture("<p>x</p>", of: figures) == false)
        #expect(ArticlePasses.containsPicture("<img src=\"https://m.e.com/other/w_900/A62339.jpg\">", of: figures))
        // A page with prose is an article, whatever its figures.
        let article = try parse("<html><head><title>T</title></head><body><article><h1>T</h1>\(p)\(p)<figure><img src='https://e.com/a.jpg'></figure></article></body></html>")
        #expect(ArticlePasses.pictureStory(article) == nil)
    }

    @Test func theCartoonPageExtractsTheCartoonNotTheFooter() async throws {
        // Readability keeps the footer here, as on the real page: nothing in the article scores.
        struct FooterOnly: ReadabilityEngine {
            func articleContent(html: String, baseURL: String) async throws -> String? {
                "<div><ul><li><a href=\"https://e.com/about\">About</a></li></ul><p>(c) 2026 Conde Nast. All rights reserved. Use of this site constitutes acceptance of our User Agreement and Privacy Policy.</p></div>"
            }
        }
        let out = try await ArticleExtraction(readability: FooterOnly()).extract(html: Self.cartoon, pageURL: "https://e.com/cartoons/daily")
        let body = try #require(out.contentHtml)
        #expect(body.contains("A62339.jpg"))
        #expect(body.contains("Cartoon by Alex Fraga"))
        #expect(!body.contains("Conde Nast"))
    }

    @Test func aPageDeclaringItselfFreeIsNotWalledBecauseOfItsSite() {
        let free = #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":true}</script>"#
        let notFree = #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        func page(_ ld: String) -> String { "<html><head><title>T</title>\(ld)</head><body><aside class=\"paywall-modal\">Already a subscriber? Sign in</aside></body></html>" }
        let url = "https://www.newyorker.com/cartoons/daily-cartoon/x"
        #expect(!PaywallDetection.isWalled(pageHTML: page(free), articleHTML: "<figure></figure>", url: url))
        #expect(PaywallDetection.isWalled(pageHTML: page(""), articleHTML: "<figure></figure>", url: url))
        #expect(PaywallDetection.isWalled(pageHTML: page(notFree), articleHTML: "<figure></figure>", url: url))
    }
}

/// The same pages through the real Readability, which is what drops each of these (needs WebKit; see ExtractionWebKitTests).
@Suite("Extraction: content platforms in WebKit", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionStructureWebKitTests {
    static let para = ExtractionStructureTests.para
    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    /// OPENDISPATCH_RAW=<file> OPENDISPATCH_RAW_URL=<url> OPENDISPATCH_RAW_OUT=<file>: the real extraction of a saved page (manual check only).
    @Test @MainActor func rawPage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["OPENDISPATCH_RAW"], let url = env["OPENDISPATCH_RAW_URL"], let out = env["OPENDISPATCH_RAW_OUT"] else { return }
        let html = try String(contentsOfFile: file, encoding: .utf8)
        let r = try await ArticleExtraction(readability: WebKitReadability.shared).extract(html: html, pageURL: url)
        try (r.contentHtml ?? "NIL").write(toFile: out, atomically: true, encoding: .utf8)
    }

    @Test @MainActor func aGhostPostWithADuplicatedPostClassKeepsItsBody() async throws {
        let html = """
        <html><head><title>Advice</title></head><body><main><div class="strip"><a href="/#posts">Posts</a><span>Advice</span></div>
        <article class="post post tag-management"><header class="phead"><h1>Advice</h1></header>
        <div class="content gh-content"><p>\(Self.para)</p><h2 id="vision">All vision, no voice</h2><p>\(Self.para)</p></div></article></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("The reader shows the whole story"))
        #expect(body.contains("All vision, no voice"))
    }

    @Test @MainActor func headingsSurviveTheirClassAndTheirWrapper() async throws {
        // Distinct paragraphs: the same paragraph in two boxes near the top is a teaser and its copy.
        let html = """
        <html><head><title>Guide</title></head><body><article><h1>Guide</h1><p>\(Self.para) (part 1)</p>
        <h2 class="header" id="h2-1"><a title="Permalink" href="#h2-1" aria-hidden="true"></a><span><strong>Governance ends in a boolean</strong></span></h2><p>\(Self.para) (part 2)</p>
        <div class="JumplinkHeader-m__jumplinkHeader" id="security"><div class="content-h2"><h2>Security</h2><a href="#security"><svg viewBox="0 0 8 8"><path d="M0 0"/></svg></a></div></div><p>\(Self.para) (part 3)</p>
        <div><div class="hkfm3h3"><h2 class="hkfm3h5">Rooq</h2><span><button aria-label="Save to a list"><svg viewBox="0 0 8 8"><path d="M0 0"/></svg></button></span></div><p>\(Self.para) (part 4)</p></div>
        </article></body></html>
        """
        let body = try await extract(html)
        for title in ["Governance ends in a boolean", "Security", "Rooq"] {
            #expect(body.contains(title), "\(title) is missing")
        }
        #expect(body.components(separatedBy: "<h2").count == 4)
    }

    @Test @MainActor func aSummaryFoldedBehindReadMoreIsKept() async throws {
        let html = """
        <html><head><title>Interview</title></head><body><main><div class="t-content"><nav class="m-breadcrumb"><ol><li><a href="/">Home</a></li></ol></nav>
        <div class="o-video-player"><div><p>To display this content from YouTube, you must enable advertisement tracking and audience measurement.</p></div>
        <figure><img src="https://e.com/a.jpg" width="1024" height="576" alt="Poster"></figure></div>
        <div class="t-content__main"><h1>Interview</h1><div class="m-box-expand"><div class="m-box-expand__content" aria-hidden="true"><p class="t-content__chapo">\(Self.para)</p></div>
        <button class="m-box-expand__button"><span>Read more</span><span>Read less</span></button></div></div></div></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("The reader shows the whole story"))
        #expect(!body.contains("Home"))
    }

    @Test @MainActor func aBloggerPostKeptInATemplateIsTheArticleNotACommentOnIt() async throws {
        let post = "<span class=\"byline-author\">Posted by A</span><br /><br />\(Self.para)<br /><br />\(Self.para)<br /><br />\(Self.para)"
        let html = """
        <html><head><title>Names of water</title></head><body><div class="post"><h2 class="title"><a href="/post">Names of water</a></h2>
        <div class="post-body"><div class="post-content" itemprop="articleBody"><script type="text/template">\(post)</script><noscript>\(post)</noscript></div></div>
        <div class="comments"><ol class="comment-list"><li class="comment"><p>Google Earth, a few points for your consideration: it is not a good idea to rename things without asking anyone at all, and here is why, at length, with commas, and more commas, and many more.</p></li></ol></div></div></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("The reader shows the whole story"))
        #expect(!body.contains("a few points for your consideration"))
    }
}

extension ExtractionStructureWebKitTests {
    /// IEEE Spectrum: the headline's box holds only the picture and its credit, and the story is in a box beside it.
    @Test @MainActor func aPictureInTheHeadlineBoxDoesNotReplaceTheStoryBesideIt() async throws {
        let html = """
        <html><head><title>Systems</title></head><body><main><article><h1>Systems</h1><div class="head"><picture><img src="https://e.com/hands.jpg" width="4000" height="2500" alt="Hands"></picture></div>
        <div class="body"><div class="photo-credit">Moor Studio/Getty Images</div></div></article>
        <div class="story"><p>\(Self.para) One.</p><p>\(Self.para) Two.</p><p>\(Self.para) Three.</p></div></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Two."))
    }
}
