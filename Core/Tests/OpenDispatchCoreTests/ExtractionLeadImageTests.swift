import Foundation
import Testing
@testable import OpenDispatchCore

/// Lead-image defects found by comparing the reader with the original pages: the lead drawn again as a body image
/// that differs only by CDN size, crop or path (MacRumors, Fox, Engadget, Business Insider, Reason, The Athletic, Medium,
/// Substack, Times of India), a sharing card with a logo or watermark (Guardian, ABC Australia, SCMP, NBC), the site's
/// own card (GitHub, og-image.png, share.png) and the page's real hero when the og:image is a card.
@Suite("Extraction: lead image")
struct ExtractionLeadImageTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)

    func has(_ body: String, _ hero: String) -> Bool { LeadImage.contentHasHero(body, hero: hero) }

    // MARK: Lead repeated by a body image

    @Test func cdnSizeSegmentsDoNotMakeAnotherImage() {
        // MacRumors: /t/<signature>/2000x/ vs /400x0/, after a paragraph.
        let lead = "https://images.macrumors.com/t/n_d_Dgnarf0QNdnuuIRoK554kLM=/2000x/article-new/2026/08/apple-app-store-ios.jpg"
        let body = "<p>\(Self.para)</p><p><img src=\"https://images.macrumors.com/t/iqct2PEMOo-5jqRhBZwUqPEbUyw=/400x0/article-new/2026/08/apple-app-store-ios.jpg?lossy\" alt=\"\"></p>"
        #expect(has(body, lead))
        // A different file in the same folder is another picture.
        #expect(!has("<p>\(Self.para)</p><p><img src=\"https://images.macrumors.com/t/x=/400x0/article-new/2026/08/other-photo.jpg\"></p>", lead))
        // Fox: /1200/675/ in the path and a proxy host in front, second image of the body.
        let fox = "https://static.foxnews.com/foxnews.com/content/uploads/2026/10/Stone_Romberg.jpg"
        let foxBody = "<p><img src=\"https://a57.foxnews.com/static.foxnews.com/foxnews.com/content/uploads/2026/10/1200/675/Romberg_family.jpg?ve=1&amp;tl=1\"></p><p>\(Self.para)</p><p><img src=\"https://a57.foxnews.com/static.foxnews.com/foxnews.com/content/uploads/2026/10/1200/675/Stone_Romberg.jpg?ve=1&amp;tl=1\"></p>"
        #expect(has(foxBody, fox))
    }

    @Test func sizeSuffixesAndPrefixesDoNotMakeAnotherImage() {
        // Engadget: l-intro-N is the large intro-N, after a standfirst.
        let engadget = "https://www.engadget.com/img/gallery/hacker/l-intro-1793300458.jpg"
        #expect(has("<p>Wired has the story.</p><p><img src=\"https://www.engadget.com/img/gallery/hacker/intro-1793300458.jpg\" width=\"780\"></p>", engadget))
        // futurecdn: -2560-80 on the lead, plain on the body's third figure.
        let future = "https://cdn.mos.cms.futurecdn.net/3ceUKRMx29vUBHrJ7wKra-2560-80.png"
        #expect(has("<img src=\"https://cdn.mos.cms.futurecdn.net/7bBDT2Cd8pNbN7jJFmrCM.png\"><p>\(Self.para)</p><img src=\"https://cdn.mos.cms.futurecdn.net/3ceUKRMx29vUBHrJ7wKra.png\">", future))
        // Reason: Kalshi.jpg vs Kalshi-800x450.jpg through a resizer path, behind a dek.
        let reason = "https://d2eehagpk5cl65.cloudfront.net/img/q60/uploads/2026/10/Kalshi.jpg"
        #expect(has("<h2>A dek about the court.</h2><p><img src=\"https://d2eehagpk5cl65.cloudfront.net/img/c800x450-w800-q80/uploads/2026/10/Kalshi-800x450.jpg\"></p>", reason))
        // ABC News: _hpMain_16x9 vs the plain _hpMain.
        #expect(has("<p>\(Self.para)</p><img src=\"https://i.abcnewsfe.com/a/5a32/AP26302_hpMain.jpg\">", "https://i.abcnewsfe.com/a/5a32/AP26302_hpMain_16x9.jpg?w=1600"))
    }

    @Test func proxiesAreUnwrapped() {
        // Medium: resize:fit:1200 vs resize:fit:1400/format:webp.
        #expect(has("<p>\(Self.para)</p><img src=\"https://miro.medium.com/v2/resize:fit:1400/format:webp/1*2TSVpCdPYj4fMMlFPuheCg.png\">",
                    "https://miro.medium.com/v2/resize:fit:1200/1*2TSVpCdPYj4fMMlFPuheCg.png"))
        // Substack: fetch URLs wrap the original; the og crop is c_fill, the body's c_limit.
        let id = "https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F976f74e8-c940-4dab-9335-98325fb003ba_1728x1000.webp"
        #expect(has("<img src=\"https://substackcdn.com/image/fetch/$s_!Uf8r!,w_1456,c_limit,f_auto/\(id)\">",
                    "https://substackcdn.com/image/fetch/$s_!9tTt!,w_1200,h_675,c_fill,f_jpg,g_auto/\(id)"))
        // The Athletic: cdn-cgi options in front of the original URL.
        #expect(has("<p>\(Self.para)</p><img src=\"https://cdn-media.theathletic.com/cdn-cgi/image/width=1920%2cquality=70/https://cdn-media.theathletic.com/YdgtwUx9MRCo_nSXaIufqAF4j_1440x960.jpg\">",
                    "https://cdn-media.theathletic.com/cdn-cgi/image/width=1200,height=630,fit=crop/YdgtwUx9MRCo_nSXaIufqAF4j_1440x960.jpg"))
        // Japan Times: premiumread's ?url= wrapper and a ?v= on the lead.
        #expect(has("<img src=\"https://cdnx.premiumread.com/?url=https://www.japantimes.co.jp/uploads/2026/10/29/571330.JPG&amp;q=100&amp;f=webp\">",
                    "https://www.japantimes.co.jp/uploads/2026/10/29/571330.JPG?v=3.1"))
        // WordPress through Jetpack's i0.wp.com.
        #expect(has("<p>\(Self.para)</p><img src=\"https://i0.wp.com/carmelitegothic.com/wp-content/uploads/2022/05/carmelite-gothic-cnc1.jpg?resize=700%2C728&amp;ssl=1\">",
                    "https://carmelitegothic.com/wp-content/uploads/2022/05/carmelite-gothic-cnc1.jpg"))
        // Times of India: msid names the picture.
        #expect(has("<img src=\"https://static.toiimg.com/thumb/msid-135326573,imgsize-310728,width-400,height-225,resizemode-4/israel.jpg\">",
                    "https://static.toiimg.com/thumb/msid-135326573,width-1280,height-720,resizemode-6,overlay-toi_sw/photo.jpg"))
    }

    @Test func aPictureSavedTwiceIsTheSamePicture() {
        // Business Insider: two object ids minted 21 s apart, the second leading the body after the byline.
        let body = "<div><p>By A. Writer</p></div><figure><img src=\"https://i.insider.com/6ae3583a81330985cf7b5495?width=700\"></figure><p>\(Self.para)</p>"
        #expect(has(body, "https://i.insider.com/6ae3584f748a9b8193ffbd1a?width=1200&format=jpeg"))
        // An hour apart is another upload.
        #expect(!has(body, "https://i.insider.com/6ae3d93a81330985cf7b5495?width=1200"))
    }

    @Test func aSharingCardGivesWayToTheBodysLeadingPicture() {
        // DeepMind: social_share card; the body leads with the header art behind a one-line standfirst.
        let card = "https://storage.googleapis.com/gweb-uniblog/images/gemini_carbon_social_share.width-1300.png"
        let body = "<p>Our strongest model.</p><p><img src=\"https://storage.googleapis.com/gweb-uniblog/images/gemini_carbon_header.width-200.format-webp.webp\" alt=\"\"></p>"
        #expect(has(body, card))
        // A card that is not a sharing card (a photo of its own) is still drawn above a different first picture.
        #expect(!has(body, "https://storage.googleapis.com/gweb-uniblog/images/some-photo.jpg"))
        // And a card is drawn when the body has no picture to lead with.
        #expect(!has("<p>\(Self.para)</p>", card))
    }

    @Test func theSameBannerUnderTwoNamesIsOnePicture() {
        // Hugging Face: thumbnail.jpg for the sharing card, header.jpg in the post under an italic subtitle.
        let body = "<p><em>An initiative bringing together universities.</em></p><p><img src=\"https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/blog/announcing-project-protostar/header.jpg\"></p>"
        #expect(has(body, "https://huggingface.co/blog/assets/announcing-project-protostar/thumbnail.jpg"))
        // A figure in the same folder is not the banner.
        #expect(!has(body.replacingOccurrences(of: "header.jpg", with: "figure-1.jpg"), "https://huggingface.co/blog/assets/announcing-project-protostar/thumbnail.jpg"))
    }

    @Test func distinctPicturesAreStillBothShown() {
        // A different image first in the body does not hide the lead.
        #expect(!has("<img src=\"https://cdn.example.com/photos/second.jpg\"><p>\(Self.para)</p>", "https://cdn.example.com/photos/first.jpg"))
        // Same folder, files that differ by a counter, are different pictures.
        #expect(!has("<p>\(Self.para)</p><img src=\"https://cdn.example.com/2026/10/chart-5.jpg\">", "https://cdn.example.com/2026/10/chart-4.jpg"))
        // Folders that differ only by the year do not make one image.
        #expect(!has("<p>\(Self.para)</p><img src=\"https://cdn.example.com/uploads/2025/10/photo.jpg\">", "https://cdn.example.com/uploads/2026/10/photo.jpg"))
    }

    @Test func aVideoThatOpensTheBodyIsTheLead() {
        let body = "<div><div><div><p><iframe src=\"https://www.youtube-nocookie.com/embed/hnCoQ5wB-GU\"></iframe></p></div><p>\(Self.para)</p></div></div>"
        #expect(has(body, "https://substackcdn.com/image/fetch/w_1200/x.png"))
        #expect(!has("<p>\(Self.para)</p><iframe src=\"https://www.youtube.com/embed/x\"></iframe>", "https://e.com/a.png"))
    }

    // MARK: Social variants

    @Test func aSharingCropBecomesThePagesPicture() {
        // Guardian: the card's overlay and precrop go, with its signature (the page's own images use s=none).
        let guardian = "https://i.guim.co.uk/img/media/75e7c001/320_316_1688_1351/master/1688.jpg?width=1200&height=630&quality=85&auto=format&fit=crop&precrop=40:21,offset-x50,offset-y0&overlay-align=bottom%2Cleft&overlay-width=100p&overlay-base64=L2ltZy9zdGF0aWMvb3ZlcmxheXMvdGctZGVmYXVsdC5wbmc&enable=upscale&s=3b9471d2fc0b900a2d8d059da97fca07"
        #expect(LeadImage.clean(guardian) == "https://i.guim.co.uk/img/media/75e7c001/320_316_1688_1351/master/1688.jpg?width=1200&dpr=1&s=none&crop=none")
        // ABC Australia's watermarked policy, SCMP's og style, NBC's 1200x630 transform.
        #expect(LeadImage.clean("https://live-production.wcms.abc-cdn.net.au/2731f6?impolicy=wcms_watermark_news&cropH=2813&width=862").contains("impolicy=wcms_crop_resize"))
        #expect(LeadImage.clean("https://cdn.i-scmp.com/sites/default/files/styles/og_image_scmp_generic/public/d8/a.jpg?itok=x").contains("/styles/1280x720/public/"))
        #expect(LeadImage.clean("https://media-cldnry.s-nbcnews.com/image/upload/t_nbcnews-fp-1200-630,f_auto,q_auto:best/rockcms/2026-10/a.jpg")
                == "https://media-cldnry.s-nbcnews.com/image/upload/t_fit-1500w,f_auto,q_auto:best/rockcms/2026-10/a.jpg")
        #expect(LeadImage.clean("https://ichef.bbci.co.uk/ace/branded_news/1200/cpsprodpb/7565/live/8d52.jpg") == "https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/7565/live/8d52.jpg")
        // Sanity (Semafor): the whole transparent graphic, flattened on white, instead of the rect crop.
        #expect(LeadImage.clean("https://img.semafor.com/6d2d-5320x3992.png?rect=0,600,5320,2793&w=1200&h=630&q=75&auto=format") == "https://img.semafor.com/6d2d-5320x3992.png?w=1200&q=75&fm=jpg&bg=fff")
        // Substack: c_limit keeps the cover whole.
        #expect(LeadImage.clean("https://substackcdn.com/image/fetch/$s_!MvMF!,w_1200,h_675,c_fill,f_jpg,q_auto:good,fl_progressive:steep,g_auto/https%3A%2F%2Fx.com%2Fa.png")
                == "https://substackcdn.com/image/fetch/$s_!MvMF!,w_1200,c_limit,f_jpg,q_auto:good,fl_progressive:steep/https%3A%2F%2Fx.com%2Fa.png")
        // WordPress and Hearst crops to 1200x630 lose their crop and keep the width.
        #expect(LeadImage.clean("https://www.usmagazine.com/wp-content/uploads/a.jpg?crop=0px%2C98px%2C1461px%2C767px&resize=1200%2C630&quality=86&strip=all")
                == "https://www.usmagazine.com/wp-content/uploads/a.jpg?quality=86&strip=all&w=1200")
        #expect(LeadImage.clean("https://9to5mac.com/wp-content/uploads/a.jpg?quality=82&strip=all&resize=1200,628") == "https://9to5mac.com/wp-content/uploads/a.jpg?quality=82&strip=all&w=1200")
        #expect(LeadImage.clean("https://images.newrepublic.com/b186.jpeg?w=1200&h=630&crop=faces&fit=crop&fm=jpg") == "https://images.newrepublic.com/b186.jpeg?w=1200&fm=jpg")
        // Photos at ordinary sizes are left alone.
        let plain = "https://example.com/wp-content/uploads/photo.jpg?w=1200&resize=800,600"
        #expect(LeadImage.clean(plain) == plain)
    }

    @Test func theSitesOwnCardIsNoLead() {
        for card in ["https://opengraph.githubassets.com/d6e0/microsoft/pylance-release",
                     "https://github.githubassets.com/assets/gist-og-image-54fd7dc0713e.png",
                     "https://tailscale.com/images/og-image.png",
                     "https://www.brangus.io/survival-llm/social-card.png",
                     "https://ghostty.org/social-share-card.jpg",
                     "https://lexifina.com/social-preview-v3.png?v=20261018",
                     "https://furbo.org/wp-content/themes/furbo/images/share.png",
                     "https://v12.sh/static/opengraph-image.png",
                     "https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/OG%20Images/agent-sdk-blog-og-WlJMIs.png"] {
            #expect(LeadImage.display(card) == nil, "\(card)")
            #expect(ArticlePasses.usableLead(card) == nil, "\(card)")
        }
        // A photo that happens to be an og crop of the article is the lead.
        let apple = "https://www.apple.com/newsroom/images/2026/10/macbook/tile/Apple-MacBook-Pro-hero-lp.jpg.og.jpg?202610281739"
        #expect(LeadImage.display(apple) == apple)
        #expect(LeadImage.display("https://example.com/photos/ogden-skyline.jpg") != nil)
        // IIIF's default.jpg is every image's file name.
        #expect(LeadImage.display("https://i.cbc.ca/ais/581c423b-92e7,1793296535290/full/max/0/default.jpg") != nil)
    }

    @Test func aThumbnailOfAnotherArticleIsNoLead() {
        let html = "<div><img src=\"https://media.springernature.com/w215h120/springer-static/image/art%3A10.1038/Figa_HTML.png\"><p>\(Self.para)</p></div>"
        #expect(ArticlePasses.firstImage(html) == nil)
    }

    // MARK: The page's own lead

    func lead(_ html: String, url: String = "https://e.com/story") throws -> String? {
        let doc = try #require(ExtractionDOM.parseDocument(html, baseURI: url))
        return ArticlePasses.chooseLead(doc, base: url)
    }

    @Test func theCardGivesWayToThePagesHero() throws {
        // Quanta: a 1200x630 og card; the lede figure is the picture.
        let html = """
        <html><head><title>T</title>
        <meta property="og:image" content="https://e.com/wp/Social-card-1.jpg"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
        </head><body><nav><img src="/logo.png" width="900" fetchpriority="high"></nav>
        <main><figure><img width="2560" height="1440" src="https://e.com/wp/Lede-scaled.webp" fetchpriority="high"></figure><p>\(Self.para)</p></main></body></html>
        """
        #expect(try lead(html) == "https://e.com/wp/Lede-scaled.webp")
        // A rewritable card keeps its picture instead.
        let nbc = html.replacingOccurrences(of: "https://e.com/wp/Social-card-1.jpg", with: "https://media-cldnry.s-nbcnews.com/image/upload/t_nbcnews-fp-1200-630,f_auto/rockcms/2026-10/a.jpg")
        #expect(try lead(nbc) == "https://media-cldnry.s-nbcnews.com/image/upload/t_fit-1500w,f_auto/rockcms/2026-10/a.jpg")
        // A 1200x630 og:image that is not marked as a card and has no page hero stays.
        #expect(try lead("<html><head><meta property=\"og:image\" content=\"https://e.com/a.jpg\"><meta property=\"og:image:width\" content=\"1200\"><meta property=\"og:image:height\" content=\"630\"></head><body><p>x</p></body></html>") == "https://e.com/a.jpg")
        // A page whose og:image is the site's card and that has no hero has no lead.
        #expect(try lead("<html><head><meta property=\"og:image\" content=\"https://e.com/og-image.png\"></head><body><p>x</p></body></html>") == nil)
    }

    /// OPENDISPATCH_LEAD_AUDIT=<dir of <n>.json> writes <dir>/hero.txt, one line per article ("n shows|hidden|none"), the
    /// app's decision for each stored extraction, to check the harness preview's Python mirror (preview.py has_hero).
    @Test func leadAudit() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENDISPATCH_LEAD_AUDIT"] else { return }
        var lines: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".json") }).sorted(by: { Int($0.dropLast(5)) ?? 0 < Int($1.dropLast(5)) ?? 0 }) {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/" + file))) as? [String: Any]
            let n = file.dropLast(5)
            guard let body = json?["html"] as? String, !body.isEmpty, let lead = LeadImage.display(json?["lead"] as? String) else { lines.append("\(n) none"); continue }
            lines.append("\(n) \(LeadImage.contentHasHero(body, hero: lead) ? "hidden" : "shows")")
        }
        try lines.joined(separator: "\n").write(toFile: dir + "/hero.txt", atomically: true, encoding: .utf8)
    }

    @Test func extractionUsesTheCleanedLead() async throws {
        let html = """
        <html><head><title>T</title><meta property="og:image" content="https://i.guim.co.uk/img/media/a/master/1.jpg?width=1200&height=630&overlay-align=bottom&overlay-base64=abc&s=sig"></head>
        <body><article><h1>T</h1><p>\(Self.para)</p><p>\(Self.para)</p></article></body></html>
        """
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: "https://e.com/story")
        #expect(out.leadImage == "https://i.guim.co.uk/img/media/a/master/1.jpg?width=1200&dpr=1&s=none&crop=none")
    }
}
