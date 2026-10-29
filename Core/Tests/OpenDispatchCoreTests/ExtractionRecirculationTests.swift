import Foundation
import Testing
@testable import OpenDispatchCore

/// Recirculation and promo chrome found by comparing the reader with the original pages (ABC News, Al Jazeera,
/// MacRumors, Business Insider, CNBC, The Atlantic, Fox, 9to5Mac, BleepingComputer, MLB, The New Republic, NASA,
/// Reason, The Athletic, CBC, The Cool Down, Simon Willison / Substack, Platformer).
@Suite("Extraction: recirculation and promos")
struct ExtractionRecirculationTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    func clean(_ html: String, base: String = "https://www.example.com/news/story") -> String {
        ArticlePasses.cleanArticle(html, base: base)
    }

    func extract(_ html: String, url: String = "https://www.example.com/news/story") async throws -> String {
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func page(_ body: String) -> String { "<html><head><title>T</title></head><body><article>\(body)</article></body></html>" }

    // MARK: Modules with a title

    @Test func recirculationTitleAloneGoes() {
        // ABC News' "Popular Reads": Readability dropped the cards and kept the title between two paragraphs.
        let out = clean("\(p)<div><section><header><div><h2>Popular Reads</h2></div></header></section></div>\(p)")
        #expect(!out.contains("Popular Reads"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func recirculationLinkListGoes() {
        // Al Jazeera's "Recommended Stories", a list of links between paragraphs.
        let out = clean("\(p)<h2>Recommended Stories </h2><ul><li><a href=\"https://e.com/a\">'If they're honest': Trump casts latest suspicion</a></li><li><a href=\"https://e.com/b\">Who is leading the polls as Trump and Harris campaign?</a></li></ul>\(p)")
        #expect(!out.contains("Recommended Stories"))
        #expect(!out.contains("casts latest suspicion"))
        #expect(out.contains("The reader shows"))
    }

    @Test func recirculationCardsWithExcerptsGo() {
        // MacRumors' "Popular Stories": picture, headline and an excerpt cut with an ellipsis, three times.
        let card = "<div><p><img alt=\"x\" src=\"https://e.com/i.jpg\"></p><div><h3>Apple Pulls Keynote From App Store</h3><p>Apple has temporarily removed Keynote, Pages, and Numbers from the App Store, just after releasing an update that added support. It is not clear why. Update: The Mac versions are back without...</p></div></div>"
        let out = clean("\(p)<div><h2>Popular Stories</h2>\(card)\(card)\(card)</div>")
        #expect(!out.contains("Popular Stories"))
        #expect(!out.contains("Keynote"))
        #expect(!out.contains("<img"))
        #expect(out.contains("The reader shows"))
    }

    @Test func recirculationTitleKeepsFollowingProse() {
        let out = clean("\(p)<h2>Read more</h2>\(p)")
        #expect(!out.contains("Read more"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func ordinaryHeadingsAndListsStay() {
        let out = clean("\(p)<h2>Further reading</h2><ul><li><a href=\"https://e.com/a\">A paper on reading comprehension</a></li></ul><p>Read more of this in the report.</p>")
        #expect(out.contains("Further reading"))
        #expect(out.contains("A paper on reading comprehension"))
        #expect(out.contains("Read more of this in the report."))
    }

    @Test func businessInsiderReadNextGoesWithItsPlaceholders() async throws {
        let card = "<article class=\"tout\"><span class=\"tout-image\"><div><img src=\"https://www.businessinsider.com/public/assets/logos/placeholder.png\" alt=\"\"></div></span><h3><span>Business Insider tells the innovative stories you want to know</span></h3></article>"
        let body = await (try? extract(page("\(p)<section class=\"read-next\"><h2 class=\"read-next-title\">Read next</h2><div class=\"read-next-list\">\(card)\(card)</div></section>"),
                                       url: "https://www.businessinsider.com/a")) ?? ""
        #expect(body.contains("The reader shows"))
        #expect(!body.contains("Read next"))
        #expect(!body.contains("placeholder.png"))
        #expect(!body.contains("Business Insider tells"))
    }

    @Test func recirculationClassBoxGoes() async throws {
        // CBC's similarLinksContainer: a list of one link to the section, mid-story.
        let body = try await extract(page("\(p)<ul class=\"similarLinksContainer-JxEul\"><li><a href=\"/news/canada/bc-north\"><p>More stories from Northern B.C.</p></a></li></ul>\(p)"))
        #expect(!body.contains("More stories from"))
        #expect(body.components(separatedBy: "page around it. </p>").count == 3)
    }

    // MARK: Labelled and shouting links

    @Test func labelledStoryLinksGo() {
        let out = clean("\(p)<p><a href=\"https://e.com/a\">Read: Here’s who Democrats want to impeach next</a></p>\(p)<p><a href=\"https://e.com/b\"><span>NEXT:</span> Rep. Steve Cohen Thinks the DEA Shouldn't Practice Medicine</a></p>")
        #expect(!out.contains("who Democrats want"))
        #expect(!out.contains("Steve Cohen"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func sentencesThatStartWithALabelStay() {
        let out = clean("\(p)<p>Read: the full report is <a href=\"https://e.com/r\">online</a> and runs to forty pages.</p>")
        #expect(out.contains("the full report is"))
    }

    @Test func shoutingLinksGo() {
        // Fox News' related and promo links.
        let out = clean("\(p)<p><a href=\"https://e.com/a\"><strong>MOM OF 2 WHO DIED RESCUING SONS DURING TRIP IS IDENTIFIED</strong></a></p>\(p)<p><a href=\"https://e.com/app\"><strong>CLICK HERE TO DOWNLOAD THE FOX NEWS APP</strong></a></p>")
        #expect(!out.contains("MOM OF 2"))
        #expect(!out.contains("DOWNLOAD"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func capitalsInProseStay() {
        let out = clean("\(p)<p>NASA</p><p><a href=\"https://e.com/n\">NASA JPL</a></p><p>THE MAN WHO FELL TO EARTH, a film in capitals with no link</p>")
        #expect(out.contains("NASA JPL"))
        #expect(out.contains("THE MAN WHO FELL"))
    }

    @Test func foxAudioWidgetGoes() {
        let out = clean("<div><p><span>NEW</span>You can now listen to Fox News articles!</p></div>\(p)")
        #expect(!out.contains("listen to Fox"))
    }

    @Test func orphanedLabelsGo() {
        let out = clean("\(p)<div><p>Editor’s Pick:</p></div>\(p)<p>Read about the firing:</p>")
        #expect(!out.contains("Editor’s Pick"))
        #expect(!out.contains("Read about the firing"))
    }

    // MARK: Affiliates, newsletters, sponsors

    @Test func affiliateAccessoryListAtTheEndGoes() {
        // 9to5Mac's "Best iPhone accessories" and its FTC line.
        let list = "<h3>Best iPhone accessories</h3><ul><li><a href=\"https://amzn.to/3Peq3Ge\">AirPods Pro 3 (<strong>now only $199</strong>)</a></li><li><a href=\"https://amzn.to/4tSJYde\">MagSafe Car Mount for iPhone</a></li></ul>"
        let out = clean("\(p)\(list)<p><em>FTC: We use income earning auto affiliate links.</em> <a href=\"https://9to5mac.com/about/#affiliate\">More.</a></p>")
        #expect(!out.contains("Best iPhone accessories"))
        #expect(!out.contains("amzn.to"))
        #expect(!out.contains("FTC:"))
        #expect(out.contains("The reader shows"))
    }

    @Test func affiliateListInTheMiddleStays() {
        let list = "<ul><li><a href=\"https://amzn.to/3Peq3Ge\">The keyboard we tested</a></li><li><a href=\"https://amzn.to/4tSJYde\">The mouse we tested</a></li></ul>"
        let out = clean("\(p)<h3>What we tested</h3>\(list)\(p)\(p)")
        #expect(out.contains("The keyboard we tested"))
    }

    @Test func starFootnoteLinkGoes() {
        let out = clean("\(p)<p><a href=\"https://e.com/refurb\"><strong>*Buy Mac with 15% discount from Apple refurbished</strong></a></p>")
        #expect(!out.contains("Buy Mac"))
    }

    @Test func newsletterPitchesGo() async throws {
        // The Cool Down: a graphic linking to the newsletter, the pitch under it, and the "Cool Picks" grid.
        let html = page("""
        \(p)<div class="wp-block-tcd-cool-gallery"><div><a href="https://www.thecooldown.com/newsletter?utm_source=x"><img src="https://www.thecooldown.com/n.jpg"></a></div></div>
        <p>Get TCD's <a href="https://www.thecooldown.com/newsletter/?utm_source=x">free newsletters</a> for easy tips, smart advice, and a chance to earn $5,000 toward home upgrades.</p>
        <div class="wp-block-tcd-cool-stories"><h2>Cool Picks</h2><a href="https://go.linkby.com/Y"><img src="https://www.thecooldown.com/p.jpg"></a><h4><a href="https://go.linkby.com/Y">Keep your dog safe</a></h4></div>
        """)
        let body = try await extract(html, url: "https://www.thecooldown.com/green-tech/story/")
        #expect(body.contains("The reader shows"))
        #expect(!body.contains("newsletter"))
        #expect(!body.contains("Cool Picks"))
        #expect(!body.contains("<img"))
    }

    @Test func newsletterPitchWithoutSiteRuleGoes() {
        // The same pitch and graphic from a site with no rule of its own, and MacRumors' sign-up block.
        let out = clean("""
        \(p)<p><a href="https://e.com/newsletter?x=1"><img src="https://e.com/n.jpg"></a></p>
        <p>Get TCD's <a href="https://e.com/newsletter/">free newsletters</a> for easy tips.</p>
        <hr><div><h2>Deals Newsletter</h2><p>Interested in hearing more about the best deals? You can <a href="http://eepurl.com/itTnTk">sign up for our Deals Newsletter</a> and we'll keep you updated.</p></div>
        <div><p>Get weekly top MacRumors stories in your inbox.</p><p>Leave this field empty</p></div>
        """)
        #expect(!out.contains("newsletter"))
        #expect(!out.contains("Newsletter"))
        #expect(!out.contains("<img"))
        #expect(!out.contains("<hr"))
        #expect(!out.contains("Leave this field"))
        #expect(out.contains("The reader shows"))
    }

    @Test func sponsorMessageGoes() {
        // Simon Willison's newsletter: a sponsor's paragraph, or a box of two, between rules.
        let out = clean("""
        <p>In this newsletter:</p><p><strong>Sponsor message:</strong><span> An agent's job isn't known until runtime.</span><a href="https://10xn.link/x">Request early access</a>.</p>\(p)
        <div><p><strong>Sponsor message:</strong><span> What's scarier than an engineer with prod access?</span></p><p><span>An AI agent with the same access.</span><a href="https://fandf.co/x">Teleport</a> shows how.</p></div>\(p)<div><p>No posts</p></div>
        """)
        #expect(out.contains("In this newsletter"))
        #expect(!out.contains("Sponsor message"))
        #expect(!out.contains("Teleport"))
        #expect(!out.contains("early access"))
        #expect(!out.contains("No posts"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func sponsoredCalloutGoes() async throws {
        // BleepingComputer's vendor-report callout.
        let html = page("\(p)<div class=\"article-callout\"><div class=\"article-media\"><a href=\"https://hubs.li/x\"><img src=\"https://www.bleepstatic.com/p.jpg\"></a></div><div class=\"article-body\"><h2><a href=\"https://hubs.li/x\">Once attackers have valid credentials</a></h2><p>Overall prevention scores can hide what happens.</p><a class=\"article-link\" href=\"https://hubs.li/x\">Get the report</a></div></div>")
        let body = try await extract(html, url: "https://www.bleepingcomputer.com/news/security/a/")
        #expect(body.contains("The reader shows"))
        #expect(!body.contains("Get the report"))
        #expect(!body.contains("<img"))
    }

    @Test func shopAdStoryPartGoes() async throws {
        // MLB.com's merchandise promo and a "read also" bullet of its own stories.
        let html = page("\(p)<div class=\"story-part dynamicinclude\"><ul><li><a href=\"https://www.mlbshop.com/brewers/x\">Get Brewers World Series champions gear!</a></li></ul></div>\(p)<ul><li><a href=\"https://www.mlb.com/news/brewers-beat-rays\">Believe it, Milwaukee! Brewers are World Series champs</a></li></ul>\(p)")
        let body = try await extract(html, url: "https://www.mlb.com/news/brewers-win")
        #expect(!body.contains("champions gear"))
        #expect(!body.contains("Believe it, Milwaukee"))
        #expect(body.components(separatedBy: "page around it. </p>").count == 4)
    }

    // MARK: Lone link lists

    @Test func relatedLinkListsBetweenParagraphsGo() {
        let out = clean("\(p)<ul><li><a href=\"https://www.example.com/news/other\">Why none of the existing partnerships are the right fit</a></li><li><a href=\"https://www.example.com/news/more\">Dropping the associate membership title for a closer alliance</a></li></ul>\(p)")
        #expect(!out.contains("existing partnerships"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 3)
    }

    @Test func introducedAndExternalLinkListsStay() {
        let intro = clean("\(p)<p>The documents are posted here:</p><ul><li><a href=\"https://www.example.com/docs/one\">The first set of documents, in full</a></li></ul>")
        #expect(intro.contains("The first set of documents"))
        let external = clean("\(p)<ul><li><a href=\"https://other.org/study\">The study the article is based on, in full</a></li></ul>")
        #expect(external.contains("The study the article"))
    }

    // MARK: End matter and tails

    @Test func pressReleaseEndMatterGoes() {
        // NASA: "-end-" and the contacts and release number below it.
        let out = clean("\(p)<p>“We’ve only scratched the surface,” Liu said.</p><p>-end-</p><p>Andrew Good<br>Jet Propulsion Laboratory<br>818-393-2433<br><a href=\"mailto:a@jpl.nasa.gov\">a@jpl.nasa.gov</a></p><p>2026-079&nbsp;</p>")
        #expect(out.contains("scratched the surface"))
        #expect(!out.contains("-end-"))
        #expect(!out.contains("Andrew Good"))
        #expect(!out.contains("2026-079"))
    }

    @Test func endMarkInTheMiddleOfALongArticleStays() {
        let out = clean("\(p)<p>-end-</p>\(p)\(p)\(p)\(p)")
        #expect(out.contains("-end-"))
        #expect(out.components(separatedBy: "page around it. </p>").count == 6)
    }

    @Test func trailingTagLinksGo() {
        // Reason: "NEXT: <story>" and the tags, run together, after the story.
        let tags = "<span><a href=\"/t/1\">Prediction Markets</a><a href=\"/t/2\">Science &amp; Technology</a><a href=\"/t/3\">Utah</a><a href=\"/t/4\">Sports</a></span>"
        let out = clean("\(p)<p><a href=\"/next\"><span>NEXT:</span> Rep. Steve Cohen Thinks the DEA Shouldn't Be Practicing Medicine</a></p><div>\(tags)</div>")
        #expect(!out.contains("Prediction Markets"))
        #expect(!out.contains("Steve Cohen"))
        #expect(out.contains("The reader shows"))
    }

    @Test func aClosingListOfLinksStays() {
        let out = clean("\(p)<ul><li><a href=\"https://a.org\">A</a></li><li><a href=\"https://b.org\">B</a></li><li><a href=\"https://c.org\">C</a></li></ul>")
        #expect(out.contains("https://c.org"))
    }

    @Test func athleticChatPromptGoes() {
        let out = clean("\(p)<ul><li>Sound off with your thoughts in the <strong><a href=\"https://e.com/chat\">game chat</a></strong> or email us: <strong><a href=\"mailto:live@theathletic.com\">live@theathletic.com</a></strong></li></ul>")
        #expect(!out.contains("Sound off"))
        #expect(!out.contains("<ul"))
    }

    @Test func substackWelcomeSectionAndPostCardGo() {
        // The author's pinned welcome under every post, then a post card.
        let out = clean("""
        \(p)\(p)<p><em>I used three AI models to help edit this article.</em></p><div><hr></div><figure><img src="https://e.com/banner.jpg"></figure>
        <h2>Subscribe for more like this</h2><p>Never miss an investigation. Always free.</p>
        <h2>What to expect</h2><p>Every investigation begins with the core insight.</p>
        <h2>Why this publication exists</h2><p>Too much reporting separates events that belong together.</p>
        <div><a href="https://e.com/p/brazil"><h2>Did Meta interfere in Brazil's presidential election?</h2></a><p>TL;DR In Brazil, Meta blocked the sitting president…</p></div>
        """)
        #expect(out.contains("used three AI models"))
        #expect(!out.contains("Subscribe for more"))
        #expect(!out.contains("What to expect"))
        #expect(!out.contains("Why this publication"))
        #expect(!out.contains("Did Meta interfere"))
        #expect(!out.contains("banner.jpg"))
    }

    @Test func subscribeHeadingEarlyInAShortPageStays() {
        let out = clean("<h2>Subscribe for more like this</h2><p>Short note.</p>")
        #expect(out.contains("Subscribe for more like this"))
    }

    // MARK: Live streams and teasers

    @Test func streamPageKeepsOnlyItsOwnPost() async throws {
        // The New Republic's /post/ pages: the requested post, then the next posts of the stream.
        let post = { (n: Int) in "<article class=\"post\"><h2>Post \(n)</h2><p>\(Self.para) Post \(n) text.</p></article>" }
        let html = "<html><head><title>T</title></head><body><article><div class=\"post-bodies\">\(post(1))\(post(2))\(post(3))</div></article></body></html>"
        let body = try await extract(html, url: "https://newrepublic.com/post/217339/donald-trump")
        #expect(body.contains("Post 1 text."))
        #expect(!body.contains("Post 2"))
        #expect(!body.contains("Post 3"))
        // Other sites' pages with several posts are left alone.
        let other = try await extract(html, url: "https://example.com/blog/")
        #expect(other.contains("Post 3 text."))
    }

    @Test func wrappersWithNothingInThemAreNoArticle() {
        #expect(ArticleExtraction.finish(readabilityContent: "<div><div>\n   \n </div></div>", media: [], base: "https://e.com/") == nil)
        #expect(ArticleExtraction.finish(readabilityContent: "<div><img src=\"https://e.com/a.jpg\"></div>", media: [], base: "https://e.com/") != nil)
    }

    @Test func walledPostWithOnlyAGridBecomesItsTeaser() async throws {
        // Platformer (Ghost): the members-only call to action, then a "Read more" grid of other posts.
        let card = "<article class=\"gh-card post\"><a href=\"/other/\"><figure><img src=\"https://e.com/i.jpg\" alt=\"Other\"></figure><div><h3>Introducing Machine Gods</h3><p>Why we're betting on AI realism. PLUS: The hell of PHP2Shell</p></div></a></article>"
        let html = """
        <html><head><title>T</title><meta property="og:description" content="Voters have other things on their minds, for now."></head><body>
        <main><article><section class="gh-content"><aside class="gh-post-upgrade-cta"><h2>This post is for paying subscribers only</h2><a href="#/portal/signup">Subscribe now</a></aside></section></article></main>
        <section class="gh-container"><h2>Read more</h2><div>\(card)\(card)</div></section></body></html>
        """
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: "https://www.platformer.news/post/")
        let body = try #require(out.contentHtml)
        #expect(body.contains("Voters have other things on their minds"))
        #expect(!body.contains("Machine Gods"))
        // Not walled: nothing found stays nothing found.
        let plain = "<html><head><title>T</title><meta property=\"og:description\" content=\"Just a blurb.\"></head><body><div></div></body></html>"
        let none = try await ArticleExtraction(readability: FakeReadability()).extract(html: plain, pageURL: "https://example.com/a")
        #expect(none.contentHtml == nil)
    }
}
