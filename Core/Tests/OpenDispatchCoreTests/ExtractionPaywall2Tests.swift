import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Walls and teaser chrome the first rounds missed: Der Spiegel's SPIEGEL+ box and print line, St. Louis Post-Dispatch's
/// TownNews cipher, the FT's barrier page, the Washington Post's byline and newsletter cards, Le Monde's header lines,
/// Nature's buy box, and New York's hidden "Already a subscriber?" template.
@Suite("Extraction: paywalls 2")
struct ExtractionPaywall2Tests {
    typealias DOM = ExtractionDOM
    static let story = "The council met on Tuesday night and voted to rebuild the bridge over the river before the spring floods return."
    static let more = "Engineers said the old span had carried twice the traffic it was built for, and the state will pay most of the bill."

    func parse(_ html: String, url: String = "https://e.com/story") throws -> Document {
        try #require(DOM.parseDocument(html, baseURI: url))
    }

    func bodyText(_ doc: Document) -> String { DOM.text(DOM.first(doc, "body")) }

    // MARK: Print-only blocks and offer boxes

    @Test func printOnlyBlocksGo() throws {
        let doc = try parse("""
        <html><body><div class="hidden print:block">Dieser Ausdruck wurde am 29.10.2026 erstellt</div>
        <div class="dn show-for-print"><span>Democracy Dies in Darkness</span></div><div class="hidden">Menu</div><p>\(Self.story)</p></body></html>
        """)
        ArticlePasses.removePrintOnly(doc)
        let text = bodyText(doc)
        #expect(!text.contains("Ausdruck") && !text.contains("Democracy"))
        #expect(text.contains("Menu") && text.contains("rebuild the bridge"))
    }

    @Test func anOfferBoxNamedPaywallGoesButAStoryWrapperStays() throws {
        let doc = try parse("""
        <html><body><article><p>\(Self.story)</p>
        <div data-area="paywall"><h3>Diesen Artikel weiterlesen mit SPIEGEL+</h3><p>1 € für 4 Wochen</p><p>Jederzeit kündigen</p></div>
        <h2 id="access-options">Access options</h2><div class="c-nature-box" data-test="entitlement-box-main"><a href="/wayf">Access through your institution</a></div>
        <div class="c-journal-buybox"><p>Subscribe to this journal</p><p>$199.00 per year</p></div>
        <div class="instant-buy-box"><p>Best Mac for most people</p><p>View Deal</p></div>
        <div data-qa="paywall-wrapper"><p>\(Self.more) \(Self.story)</p></div></article></body></html>
        """)
        ArticlePasses.removeOfferBoxes(doc)
        let text = bodyText(doc)
        for gone in ["SPIEGEL+", "Access options", "institution", "Subscribe to this journal"] { #expect(!text.contains(gone), "\(gone) is still there") }
        #expect(text.contains("Best Mac for most people"))
        #expect(text.contains("state will pay most of the bill"))
    }

    // MARK: TownNews

    static let townNews = """
    <html><head><title>Kirkwood OKs apartments</title><meta property="og:title" content="Kirkwood OKs apartments">
    <meta itemprop="isAccessibleForFree" content="false"/></head><body><div class="tnt-headline"><h1>Kirkwood OKs apartments</h1></div>
    <div itemprop="articleBody" id="article-body" class="asset-content subscriber-premium" data-content-encrypted="true">
    <div class="subscriber-preview lee-article-text first-p"><p>\(story)</p></div>
    <div class="subscriber-only encrypted-content lee-article-text" style="display:none">kAm%96 2A2CE&gt;6?ED H@F=5 C2?86k^Am</div>
    <div class="inline-asset tnt-inline-asset tnt-inline-relcontent tnt-inline-image"><figure class="photo"><div itemprop="image">
    <meta itemprop="contentUrl" content="https://bloximages.example.com/site.com/editorial/a/b/photo.image.jpg?resize=1200%2C800">
    <img src="data:image/png;base64,iVBORw0KGgo=" alt="The public works site"></div>
    <figcaption class="caption"><span class="caption-text"><p>The public works complex on Fillmore Avenue.</p></span><span class="credit">Jane Roe, Post-Dispatch</span></figcaption></figure></div>
    <div class="inline-asset tnt-inline-asset tnt-inline-relcontent tnt-inline-article"><h3>Related: Blues shake up lines</h3></div>
    <div class="p402_hide hidden-print"><h2>Be the first to know</h2></div></div>
    <div id="inline-article-recommend"><h3>People are also reading…</h3></div></body></html>
    """

    @Test func aTownNewsCipheredStoryIsItsPreviewAndPictures() throws {
        let doc = try parse(Self.townNews, url: "https://www.stltoday.com/news/article_1.html")
        ArticlePasses.removeTownNewsWall(doc)
        let body = try #require(DOM.first(doc, "body"))
        let html = DOM.innerHTML(body)
        #expect(html.contains("rebuild the bridge"))
        #expect(html.contains("photo.image.jpg?resize=1200%2C800"))
        #expect(html.contains("<figcaption>The public works complex on Fillmore Avenue. Jane Roe, Post-Dispatch</figcaption>"))
        #expect(DOM.first(body, "h1") != nil)
        for gone in ["kAm%96", "Blues shake up", "Be the first", "People are also reading"] { #expect(!html.contains(gone), "\(gone) is still there") }
    }

    @Test func townNewsMicrodataWallsAShortStory() {
        let url = "https://www.stltoday.com/news/article_1.html"
        #expect(PaywallDetection.isWalled(pageHTML: Self.townNews, articleHTML: "<p>\(Self.story)</p>", url: url))
        let encrypted = "<html><body><div data-content-encrypted=\"true\"><p>\(Self.story)</p></div></body></html>"
        #expect(PaywallDetection.isWalled(pageHTML: encrypted, articleHTML: "<p>\(Self.story)</p>", url: url))
        let plain = "<html><body><p>\(Self.story)</p></body></html>"
        #expect(!PaywallDetection.isWalled(pageHTML: plain, articleHTML: "<p>\(Self.story)</p>", url: url))
    }

    @Test func townNewsRelatedCardsGoOnAnOpenStoryToo() throws {
        let doc = try parse("""
        <html><body><div id="article-body" class="asset-content"><p>\(Self.story)</p>
        <div class="tnt-inline-relcontent tnt-inline-link"><a href="/b">Blues shake up lines</a></div>
        <div class="tnt-inline-relcontent tnt-inline-image"><img src="https://e.com/a.jpg" alt=""></div><p>\(Self.more)</p></div></body></html>
        """)
        ArticlePasses.removeTownNewsWall(doc)
        let text = bodyText(doc)
        #expect(!text.contains("Blues shake up"))
        #expect(text.contains("rebuild the bridge") && text.contains("most of the bill"))
        #expect(DOM.first(doc, "img[src=https://e.com/a.jpg]") != nil)
    }

    // MARK: Header lines

    @Test func theTitleHeadersBylineDateLabelAndLanguageSwitchGo() throws {
        let doc = try parse("""
        <html><head><title>Behind Trump's shift</title><meta property="og:title" content="Behind Trump's shift"></head><body><article>
        <header><h1>Behind Trump's shift</h1><div class="ds-description"><span>Kirill Dmitriev has been working to persuade the White House.</span></div>
        <p class="meta"><span>By&nbsp;<a href="/en/signataires/a/">Claire Gatinois</a> and <a href="/en/signataires/b/">Benjamin Quénelle</a> (Istanbul, special correspondent)</span></p>
        <section><span>Published today at 5:31 pm (Paris)</span> <a hreflang="fr" href="/international/article/x.html"><span>Lire en français</span></a></section>
        <p class="ds-article-status"><svg viewBox="0 0 16 16"></svg><span>Subscribers only</span></p>
        <div><time datetime="2026-10-16 09:33:00">16.10.2026, 09.33 Uhr</time></div><p><time>Oct 29, 2026</time> · 1 minute read</p></header>
        <p>\(Self.story) The <a hreflang="de" href="/de/x">German edition</a> has more.</p></article></body></html>
        """)
        ArticlePasses.removeAccessLabels(doc)
        ArticlePasses.removeLanguageSwitches(doc)
        ArticlePasses.removeTitleHeaderMeta(doc)
        let text = bodyText(doc)
        for gone in ["Claire Gatinois", "Published today", "Lire en français", "Subscribers only", "09.33 Uhr"] { #expect(!text.contains(gone), "\(gone) is still there") }
        #expect(text.contains("Kirill Dmitriev has been working"))
        #expect(text.contains("German edition"))
        // Part of a line stays with its line.
        #expect(text.contains("Oct 29, 2026 · 1 minute read"))
    }

    @Test func bylinesOutsideTheTitleHeaderStay() throws {
        let doc = try parse("""
        <html><head><title>Bridge vote</title></head><body><article><h1>Bridge vote</h1><p>By Tuesday the council had voted.</p><p>\(Self.story)</p></article></body></html>
        """)
        ArticlePasses.removeTitleHeaderMeta(doc)
        #expect(bodyText(doc).contains("By Tuesday the council had voted."))
    }

    // MARK: Cards and pitches

    @Test func testAttributeBylineAndNewsletterCardsGo() throws {
        let doc = try parse("""
        <html><body><article><div data-testid="byline-container"><div data-qa="author-byline"><img src="https://e.com/author.png" width="196" height="196">
        <span data-testid="byline-attribution">Column by </span><a rel="author" href="/people/m">Michael J. Coren</a></div>
        <div>Michael Coren's Future Coach column explores the choices that shape how we live.</div></div><p>\(Self.story)</p>
        <div data-qa="newsletter"><div data-qa="sc-newsletter-signup"><img src="/dr/resources/images/generic-newsletter-signup.png" width="166" height="110"><button>Sign up</button></div></div>
        </article></body></html>
        """)
        ArticlePasses.removeTestAttributeCards(doc)
        let html = DOM.innerHTML(try #require(DOM.first(doc, "body")))
        #expect(!html.contains("Future Coach") && !html.contains("author.png") && !html.contains("newsletter-signup"))
        #expect(html.contains("rebuild the bridge"))
    }

    @Test func subscriptionPitchesInTheTextGo() throws {
        let doc = try parse("""
        <html><body><article><p>\(Self.story)</p><p><strong><em>DER SPIEGEL relies on support from its readers. To enjoy the rest of this story, please consider signing up for a subscription to The German View.</em></strong></p>
        <p>In a time of both misinformation and too much information, quality journalism is more crucial than ever.<br>By subscribing, you can help us get the story right.</p>
        <p>Readers who subscribe to the council's newsletter learned of the vote first.</p></article></body></html>
        """)
        ArticlePasses.removeSubscriptionPitches(doc)
        let text = bodyText(doc)
        #expect(!text.contains("relies on support") && !text.contains("By subscribing"))
        #expect(text.contains("rebuild the bridge") && text.contains("newsletter learned of the vote"))
    }

    // MARK: Barrier pages and phrases

    @Test func aBarrierPageIsItsDescriptionPaywalled() async throws {
        let page = """
        <html><head><title>Subscribe to read</title><meta property="og:description" content="Google owner admits AI mode has hurt traditional search.">
        <script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":"False"}</script></head>
        <body><article><p><span>Subscribe to unlock this article</span></p><h2>Try unlimited access</h2><p>Only $1 for 4 weeks. Then $75 per month. Complete digital access to quality journalism on any device.</p></article></body></html>
        """
        let url = "https://www.ft.com/content/eb386156"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: page, pageURL: url)
        let html = try #require(out.contentHtml)
        #expect(html.contains("Google owner admits"))
        #expect(!html.contains("unlock") && !html.contains("$75"))
        #expect(PaywallDetection.isWalled(pageHTML: page, articleHTML: html, url: url))
    }

    @Test func aWallPhraseInAHiddenTemplateIsNoSignal() {
        let article = "<p>\(Self.story) \(Self.more)</p>"
        let hidden = "<html><body><article>\(article)</article><div class=\"border hidden\"><div>Already a subscriber? <button>Sign In</button></div></div></body></html>"
        #expect(!PaywallDetection.isWalled(pageHTML: hidden, articleHTML: article, url: "https://www.vulture.com/article/a.html"))
        let shown = "<html><body><article>\(article)</article><div class=\"wall\"><div>Already a subscriber? <button>Sign In</button></div></div></body></html>"
        #expect(PaywallDetection.isWalled(pageHTML: shown, articleHTML: article, url: "https://www.vulture.com/article/a.html"))
    }
}
