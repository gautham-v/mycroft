import Foundation
import Testing
@testable import OpenDispatchCore

/// Promos and recirculation the first rounds kept (BBC, TechRadar, Tom's Hardware, PBS, Scientific American, 9to5Google,
/// Gizmodo, GitHub, TV Insider, Metro, the New York Post, Us Weekly, Eater, France 24, Times Now, Macworld, DeepMind,
/// Vogue, People, The Ringer, the Express, the Daily Beast, Investopedia, Cricinfo, hashnode).
@Suite("Extraction: promos, second round")
struct ExtractionPromos2Tests {
    static let first = String(repeating: "The council met on Tuesday to settle the budget for the coming year. ", count: 4)
    static let second = String(repeating: "Residents asked about the bridge repairs and the late buses downtown. ", count: 4)
    var p1: String { "<p>\(Self.first)</p>" }
    var p2: String { "<p>\(Self.second)</p>" }

    func clean(_ html: String, base: String = "https://www.example.com/news/story") -> String {
        ArticlePasses.cleanArticle(html, base: base)
    }

    func extract(_ body: String, url: String = "https://www.example.com/news/story") async throws -> String {
        let html = "<html><head><title>T</title></head><body><article>\(body)</article></body></html>"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func bothParagraphs(_ out: String) -> Bool { out.contains("settle the budget") && out.contains("late buses") }

    // MARK: Modules on the page

    @Test func titledModuleGoesWithItsCards() async throws {
        // GitHub's "Related posts": Readability dropped the heading and kept the cards.
        let cards = (1...3).map { "<article class=\"post-card\"><img src=\"https://e.com/\($0).jpg\"><h3><a href=\"https://e.com/p\($0)\">Post number \($0) about agents</a></h3><p>A short blurb for the post.</p></article>" }.joined()
        let out = try await extract("\(p1)\(p2)<section class=\"container\"><h2 class=\"title\">Related posts</h2><div class=\"post-columns\">\(cards)</div></section>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Post number"))
    }

    @Test func relatedHeadingOverProseStays() async throws {
        let out = try await extract("\(p1)<section><h2>Related</h2>\(p2)<p>See <a href=\"https://e.com/a\">the agenda</a> and <a href=\"https://e.com/b\">the minutes</a>.</p></section>")
        #expect(out.contains("late buses"))
        #expect(out.contains("the agenda"))
    }

    @Test func recirculationClassBoxGoes() async throws {
        // Eater's map footer, Metro's "Deals of the Day" carousel.
        let out = try await extract("\(p1)<div class=\"metro-more-from\"><header><h4>Deals of the Day</h4></header><ul><li><a href=\"https://e.com/v\"><img src=\"https://e.com/v.jpg\"><p>This vacuum is a game-changer for pet owners</p></a></li><li><a href=\"https://e.com/c\"><p>The candle brand has launched its biggest sale</p></a></li></ul></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("game-changer"))
        #expect(!out.contains("Deals of the Day"))
    }

    @Test func donationBoxGoes() async throws {
        // PBS: the button is what marks it.
        let out = try await extract("\(p1)\(p2)<div class=\"inline-invite\"><div class=\"invite_heading\">A free press is a cornerstone of a healthy democracy.</div><p>Support trusted journalism and civil dialogue.</p><a href=\"https://give.example.org/page/1/donate/1\"><button>Donate now</button></a></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("free press"))
    }

    // MARK: Follow on Google

    @Test func googleFollowLineAndPictureGo() {
        let out = clean("\(p1)\(p2)<a href=\"https://news.google.com/publications/CAAq\"><figure><img src=\"https://e.com/g.jpg\" alt=\"Google logo next to text reading 'Click to follow'\"></figure></a><p><a href=\"https://news.google.com/publications/CAAq\"><em><strong>Follow TechRadar on Google News</strong></em></a> and <a href=\"https://www.google.com/preferences/source?q=techradar.com\">add us as a preferred source</a> to get our expert news in your feeds.</p>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Google"))
        #expect(!out.contains("<img"))
    }

    @Test func preferredSourcePitchGoes() {
        let out = clean("\(p1)<p><strong><em>To see more of the stories you love from The Mirror and to find them easily in Google then make us your preferred source. Free and easy-to-do.</em></strong></p>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("preferred source"))
    }

    // MARK: Titled teasers

    @Test func relatedListWithBylinesAndTagsGo() {
        // PBS: "Related" with a byline under each link, then "Go Deeper" over the tags.
        let items = ["Judge extends order blocking the ban on reporters", "Reporters have access restored after the order"].map {
            "<li><a href=\"https://www.pbs.org/newshour/politics/x\"><span>\($0)</span></a> <p><span>By</span> Hallie Golden, Associated Press</p></li>"
        }.joined()
        let out = clean("\(p1)\(p2)<div><h2>Related</h2><ul>\(items)</ul><h2>Go Deeper</h2><ul><li><a href=\"https://www.pbs.org/newshour/tag/cnn\">cnn</a></li><li><a href=\"https://www.pbs.org/newshour/tag/first-amendment\">first amendment</a></li></ul></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Hallie Golden"))
        #expect(!out.contains("Go Deeper"))
        #expect(!out.contains("first amendment"))
    }

    @Test func moreOnListGoes() {
        // 9to5Google's "More on Google Home:".
        let out = clean("\(p1)\(p2)<div><h2>More on Google Home:</h2><ul><li><a href=\"https://9to5google.com/a\">Amazon's latest Echo displays reinforce the lead</a></li><li><a href=\"https://9to5google.com/b\">Halloween doorbell chimes are live now</a></li></ul></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("More on Google Home"))
        #expect(!out.contains("doorbell"))
    }

    @Test func excerptUnderSeriesTitleGoes() {
        // Slate's "More Parenting Advice From Slate": an excerpt that ends in a link to the rest.
        let out = clean("\(p1)\(p2)<h3>More Parenting Advice From Slate</h3><div><p>A few months ago, a mysterious package arrived in the mail addressed to my daughter. <a href=\"https://slate.com/advice/2018/06/x.html\">My two sons had birthdays in the months before.</a></p></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("mysterious package"))
    }

    @Test func inlineRelatedCardGoes() {
        // TV Insider: a linked picture, "Related", and the other story's headline between paragraphs.
        let out = clean("\(p1)<div><p><a href=\"https://www.tvinsider.com/swooon/1/x/\"><img src=\"https://e.com/x.jpg\" alt=\"All About the Romance\"></a></p><p>Related</p><h3>All About the Romance &amp; More</h3></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Romance"))
        #expect(!out.contains("<img"))
    }

    // MARK: Calls to action

    @Test func getInTouchBoxGoes() {
        // BBC.
        let out = clean("\(p1)\(p2)<div><h2>Get in touch</h2><div><p>Are you affected by issues covered in this story? Share your experiences.</p></div></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Get in touch"))
        #expect(!out.contains("affected"))
    }

    @Test func appDownloadHeadingAndLinksGo() {
        // The New York Post's footer.
        let out = clean("\(p1)\(p2)<hr><h2><strong>Download The California Post App, follow us on social, and subscribe to our newsletters</strong></h2><div><p><strong>California Post News</strong>: <a href=\"https://facebook.com/x\">Facebook</a>, <a href=\"https://instagram.com/x\">Instagram</a>, <a href=\"https://x.com/x\">X</a></p></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Download"))
        #expect(!out.contains("Instagram"))
        #expect(!out.contains("<hr"))
    }

    @Test func supportingJournalismPitchGoes() {
        // Scientific American, between two paragraphs with a rule on each side.
        let out = clean("\(p1)<hr><h2>On supporting science journalism</h2><p>If you're enjoying this article, consider supporting our award-winning journalism by <a href=\"https://e.com/getsciam/\">subscribing</a>.</p><hr>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("supporting"))
    }

    @Test func newsletterBoxGoesButNewsletterSectionStays() {
        let out = clean("\(p1)<div><h4>The Soaps Newsletter – Weekly</h4><p>Sign up for exclusive spoilers and interviews.</p></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Soaps"))
        let story = clean("<h2>The newsletter</h2><p>It began as a weekly email.</p>\(p1)\(p2)")
        #expect(story.contains("weekly email"))
    }

    @Test func subscribeBoxGoes() {
        // People's "VIPs Get More".
        let out = clean("\(p1)<div><h3>VIPs Get More</h3><p>The stories you love, with first access reserved for subscribers.</p><a href=\"https://people.com/vip\"><span>Subscribe Now</span></a></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("VIPs"))
    }

    // MARK: Promo lines

    @Test func promoLinesGo() {
        let lines = [
            "<blockquote><p>Want more io9 news? Check out <a href=\"https://gizmodo.com/tag/x\">the best movies</a> to stream this month.</p></blockquote>",
            "<div><p><span>REG AD</span></p></div>",
            "<div><p><span>Video from Slate</span></p></div>",
            "<p><span>Best Prices Today: </span></p>",
            "<div><p>More on the NBA </p><p>More on the NBA </p></div>",
            "<p><a href=\"https://www.foxnews.com/tips\"><strong>GOT A TIP?</strong></a></p>",
        ]
        for line in lines {
            let out = clean("\(p1)\(line)\(p2)")
            #expect(bothParagraphs(out))
            #expect(!out.contains("io9") && !out.contains("REG AD") && !out.contains("Video from") && !out.contains("Best Prices") && !out.contains("NBA") && !out.contains("TIP"), "\(line)")
        }
    }

    @Test func signUpFormGoesWhole() {
        // The Express' newsletter form, its blurb with it.
        let out = clean("\(p1)<div><p>Get the latest politics news - straight from our team in Westminster and more</p><p>I would like to receive emails from the Daily Express featuring our latest products.</p><p><span>Invalid email</span></p><p>You agree you are 18 or over. You can unsubscribe at any time.</p></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Westminster"))
        #expect(!out.contains("Invalid"))
    }

    @Test func labelledLinksGo() {
        let out = clean("\(p1)<p><a href=\"https://www.pbs.org/a\"><strong>READ MORE:</strong> Judge extends order blocking the ban</a></p><p><span>MORE: <a href=\"https://metro.co.uk/b\">Kim rocked by two game-changing shocks</a></span></p><p><span>Read more</span><a href=\"https://www.france24.com/c\">France faces reckoning with public order policing</a></p>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Judge") && !out.contains("Kim rocked") && !out.contains("reckoning"))
    }

    // MARK: Pictures and cards

    @Test func bannerPicturesGo() {
        let out = clean("\(p1)\(p2)<div><figure><p><span><img src=\"https://e.com/b.png\" alt=\"Thin, red banner promoting the Politics Essential newsletter\"></span></p></figure></div><div><p><img src=\"https://e.com/h.png\" alt=\"Best antivirus software header\"></p></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("<img"))
    }

    @Test func captionedBannerStays() {
        let out = clean("\(p1)<figure><img src=\"https://e.com/b.jpg\" alt=\"Protesters hold a banner image of the leader\"><figcaption>Protesters outside parliament.</figcaption></figure>\(p2)")
        #expect(out.contains("<img"))
    }

    @Test func affiliateTileGoes() {
        // Us Weekly's "Deal of the Day" watch.
        let out = clean("\(p1)<div><a href=\"https://o.bttn.io/1FrV\"><figure><div><p><img src=\"https://e.com/watch.png\" alt=\"Bracelet Watch\"></p></div></figure></a></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("watch.png"))
    }

    @Test func endOfArticleTakesAuthorCard() {
        // Times Now.
        let out = clean("\(p1)\(p2)<div><div><p><img src=\"https://e.com/authorthumb/1.cms\" alt=\"Govind Choudhary\"></p><div><p><strong>Govind Choudhary <span>author</span></strong></p><p>Govind Choudhary is the Chief Copy Editor for Tech.</p></div></div><p>End of Article</p></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Govind") && !out.contains("End of Article"))
    }

    @Test func videoCardLeftoversGo() {
        // France 24: the poster with "Cover image" and the duration, and the title line above it.
        let out = clean("\(p1)<div><p>French Senate debates new bill</p><div><figure><img src=\"https://e.com/v.png\" alt=\"BUSINESS\"><figcaption>Cover image: BUSINESS © FRANCE 24</figcaption><p>03:46</p></figure></div></div>\(p2)")
        #expect(bothParagraphs(out))
        #expect(!out.contains("Senate") && !out.contains("Cover image") && !out.contains("03:46"))
    }

    @Test func trailingTagLabelGoes() {
        let out = clean("\(p1)\(p2)<hr><div><p>CATEGORIES</p></div>")
        #expect(bothParagraphs(out))
        #expect(!out.contains("CATEGORIES") && !out.contains("<hr"))
    }

    // MARK: Trailing link lists

    @Test func trailingTagListGoes() {
        // Business Insider's category chips, with a "More" toggle among them.
        let out = clean("\(p1)\(p2)<div><ul><li><a href=\"https://www.businessinsider.com/category/google\">Google</a></li><li><a href=\"https://www.businessinsider.com/category/ai\">AI</a></li><li><span>More </span></li></ul></div>", base: "https://www.businessinsider.com/x")
        #expect(bothParagraphs(out))
        #expect(!out.contains("category"))
    }

    @Test func trailingSameSiteHeadlinesGo() {
        // cleveland.com's related recalls after the last paragraph.
        let items = ["pair-of-toyota-recalls-announced", "ford-announces-3-different-recalls", "luxury-electric-suvs-recalled", "toyota-suvs-recalled-over-fuel-leak", "automaker-issues-do-not-drive-recall"].map {
            "<li><a href=\"https://www.cleveland.com/news/2026/10/\($0).html\">\($0.replacingOccurrences(of: "-", with: " ")) for owners</a></li>"
        }.joined()
        let out = clean("\(p1)\(p2)<ul>\(items)</ul>", base: "https://www.cleveland.com/news/2026/10/story.html")
        #expect(bothParagraphs(out))
        #expect(!out.contains("toyota"))
    }

    @Test func trailingSourcesListStays() {
        let items = ["first-report", "second-report", "third-report"].map {
            "<li><a href=\"https://www.cleveland.com/news/2026/10/\($0).html\">The \($0.replacingOccurrences(of: "-", with: " ")) from the county</a></li>"
        }.joined()
        let out = clean("\(p1)\(p2)<p>Sources:</p><ul>\(items)</ul>", base: "https://www.cleveland.com/news/2026/10/story.html")
        #expect(out.contains("first report"))
    }
}
