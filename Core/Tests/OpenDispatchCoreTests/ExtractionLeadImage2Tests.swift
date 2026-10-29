import Foundation
import Testing
@testable import OpenDispatchCore

/// Lead image, round 2: an id that names a site is not an image's name (Platformer's Ghost storage UUID), Google's
/// =w sizes, a player under a series banner (Lenny's), the sharing card a site draws at /image/16x9 (Kadoa) and logo
/// thumbnails (Blogger), a 200px src with the real sizes in its srcset (DeepMind).
@Suite("Extraction: lead image 2")
struct ExtractionLeadImage2Tests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)

    func has(_ body: String, _ hero: String) -> Bool { LeadImage.contentHasHero(body, hero: hero) }

    @Test func aSiteIDInTheFolderIsNotTheImage() {
        // Platformer: every image of the site lives under the same storage UUID.
        let lead = "https://storage.ghost.io/c/a0/4c/a04c7225-d919-4d78-9b7c-a3fdd071349b/content/images/size/w1200/2026/10/20260911_jchou_MachineGod_0961.jpg"
        let body = "<p>\(Self.para)</p><img src=\"https://storage.ghost.io/c/a0/4c/a04c7225-d919-4d78-9b7c-a3fdd071349b/content/images/2026/09/MG_CoverPhoto_Centered_WhiteOnOlive.png\">"
        #expect(!has(body, lead))
        // The photo itself, from the same storage in another size, is still the lead.
        #expect(has("<p>\(Self.para)</p><img src=\"https://storage.ghost.io/c/a0/4c/a04c7225-d919-4d78-9b7c-a3fdd071349b/content/images/2026/10/20260911_jchou_MachineGod_0961.jpg\">", lead))
        // Webflow's /<site id>/ and Hugging Face's /<user id>/ are shared by the body's pictures too.
        let webflow = "https://cdn.prod.website-files.com/6a146a5aca0b1a41051708a5/6adf6b3b5ddc1bc1311cd370_6a32a0cab8a1061a5787637e_17.jpeg"
        let webflowBody = "<p>\(Self.para)</p><img src=\"https://cdn.prod.website-files.com/6a146a5aca0b1a41051708a5/6ae0916527e477c7abbb7f44_fig-01.jpeg\"><img src=\"https://cdn.prod.website-files.com/6a146a5aca0b1a41051708a5/6adf8c6612cf8377560226a2_fig-02.png\">"
        #expect(!has(webflowBody, webflow))
    }

    @Test func anImageFolderIdStillNamesTheImage() {
        // The New Yorker / Vogue: the object id is the picture's folder, the crop is a size segment.
        #expect(has("<p>\(Self.para)</p><img src=\"https://media.newyorker.com/cartoons/6ae34c249e899c2b470ba00a/master/w_1600%2Cc_limit/A62339.jpg\">",
                    "https://media.newyorker.com/photos/6ae34c249e899c2b470ba00a/16:9/w_1280,c_limit/A62339.jpg"))
        // The Times: one folder per picture, the file name carries the rendition.
        #expect(has("<p>\(Self.para)</p><img src=\"https://static01.nyt.com/images/2026/10/28/multimedia/00dc-chips-01-zhpm/00dc-chips-01-zhpm-articleLarge.jpg?quality=75\">",
                    "https://static01.nyt.com/images/2026/10/28/multimedia/00dc-chips-01-zhpm/00dc-chips-01-zhpm-facebookJumbo.jpg"))
        // New York: the id leads the file name.
        #expect(has("<p>\(Self.para)</p><img src=\"https://pyxis.nymag.com/v1/imgs/a38/ab1/434aba2dd9876cafe6b9ff3acf0f415a1b-gore-week.2x.rvertical.w570.jpg\">",
                    "https://pyxis.nymag.com/v1/imgs/a38/ab1/434aba2dd9876cafe6b9ff3acf0f415a1b-gore-week.1x.rsocial.w1200.jpg"))
    }

    @Test func googleSizesAreNotAnotherFile() {
        let id = "wAQ6wnzu6Lr-VMuS6ielTWpKEcpB2PkjN0XTdby80-NtefdPj9-ZKCrVPk-CSPuZ6GN8B4sScphV7sUd9dwrgprBrijy8wj3Z9fIv7eg2QAcMUMGPA"
        #expect(has("<p>\(Self.para)</p><img src=\"https://lh3.googleusercontent.com/\(id)=w704-h704-n-nu\">", "https://lh3.googleusercontent.com/\(id)=w1440-h810-n-nu"))
        #expect(!has("<p>\(Self.para)</p><img src=\"https://lh3.googleusercontent.com/other\(id)=w1440-h810-n-nu\">", "https://lh3.googleusercontent.com/\(id)=w1440-h810-n-nu"))
    }

    @Test func aPlayerUnderASeriesBannerLeads() {
        // Lenny's: a "How I AI" strip (2329x551), a line of title, then the player; the episode card above it is redundant.
        let lead = "https://substackcdn.com/image/fetch/$s_!MvMF!,w_1200,c_limit,f_jpg/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fb3ec454d-2a57-4dac-9f09-3d0762816acf_1456x1048.png"
        let banner = "<img src=\"https://substackcdn.com/image/fetch/$s_!gWeJ!,w_1456,c_limit,f_auto/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F361d81ef-7faf-4d8e-8028-5d5e03432a9a_2329x551.png\">"
        let player = "<iframe src=\"https://www.youtube-nocookie.com/embed/zF-J3rMbzZw?rel=0\"></iframe>"
        #expect(has("<figure>\(banner)</figure><h3>Why Reddit built its own AI prototyping tool</h3><div>\(player)</div><p>\(Self.para)</p>", lead))
        // A real photo before the player, a chart frame, or a long standfirst: the lead stays.
        let photo = "<img src=\"https://e.com/a/photo_1600x900.jpg\">"
        #expect(!has("<figure>\(photo)</figure><div>\(player)</div><p>\(Self.para)</p>", lead))
        #expect(!has("<figure>\(banner)</figure><div><iframe src=\"https://datawrapper.dwcdn.net/abc/1/\"></iframe></div><p>\(Self.para)</p>", lead))
        #expect(!has("<figure>\(banner)</figure><p>\(Self.para)</p><div>\(player)</div>", lead))
    }

    @Test func generatedCardRoutesAndLogosAreNotLeads() {
        // Kadoa/Bettascore: /<post>/image/16x9 draws the headline and a chart again.
        #expect(LeadImage.display("https://www.bettascore.ai/research/reliability-reviewers-vs-owners/image/16x9") == nil)
        #expect(LeadImage.display("https://example.com/blog/post/opengraph-image-a1b2c3") == nil)
        // A photo in a folder called image stays.
        #expect(LeadImage.display("https://example.com/image/photo-16x9.jpg") != nil)
        // Blogger's default thumbnail.
        #expect(LeadImage.display("https://blogger.googleusercontent.com/img/b/R29vZ2xl/AVvX/s1600/googlelogo_color_200x200.png") == nil)
        #expect(LeadImage.display("https://example.com/uploads/site-logo.svg") == nil)
        #expect(LeadImage.display("https://example.com/uploads/catalog-photo.jpg") != nil)
        // A photo that names a logo in its slug or credit is a photo (Quanta, Android Police).
        #expect(LeadImage.display("https://www.quantamagazine.org/wp-content/uploads/2026/10/JOW-S5-E11-cr.Chanelle-Nibbelink-Lede-LOGO-scaled.webp") != nil)
        #expect(LeadImage.display("https://static0.anpoimages.com/wordpress/wp-content/uploads/2026/10/3d-youtube-premium-logo-emerging.png?w=1600") != nil)
        // Dotdash Meredith names each crop of a photo <id>-<slug>-<ratio>-<hash>.
        #expect(has("<p>\(Self.para)</p><img src=\"https://www.allrecipes.com/thmb/2XNWiq=/1500x0/filters:no_upscale():strip_icc()/11796972-Swamp-Soup-Beauty-4x3-1e63452a042d4e008124c60daf3adbe4.jpg\">",
                    "https://www.allrecipes.com/thmb/RPyvtj=/1500x0/filters:no_upscale():strip_icc()/11796972-Swamp-Soup-Beauty-2x1-a22c6b3a042d4e008124c60daf3adbe4.jpg"))
    }

    @Test func aTinySrcTakesTheSrcsetsRealSize() throws {
        // DeepMind: og:image is the social_share card; the page's hero has src ...width-200 and sizes in srcset.
        let html = """
        <html><head><meta property="og:image" content="https://s.googleapis.com/images/gemini_social_share.width-1300.png"></head>
        <body><article><p><img alt="" src="https://s.googleapis.com/images/gemini_header.width-200.format-webp.webp"
          data-srcset="https://s.googleapis.com/images/gemini_header.width-450.format-webp.webp 450w, https://s.googleapis.com/images/gemini_header.width-1200.format-webp.webp 1200w, https://s.googleapis.com/images/gemini_header.width-2200.format-webp.webp 2200w"
          width="1200" fetchpriority="high"></p><p>\(Self.para)</p></article></body></html>
        """
        let doc = try #require(ExtractionDOM.parseDocument(html, baseURI: "https://e.com/story"))
        #expect(ArticlePasses.chooseLead(doc, base: "https://e.com/story") == "https://s.googleapis.com/images/gemini_header.width-1200.format-webp.webp")
        // That lead is the body's own picture, whichever size the body's src names.
        #expect(has("<p><img src=\"https://s.googleapis.com/images/gemini_header.width-200.format-webp.webp\"></p>", "https://s.googleapis.com/images/gemini_header.width-1200.format-webp.webp"))
    }

    @Test func anOGImageWithThePagesPictureAltIsThatPicture() throws {
        // BBC: the sharing file was swapped for another shot of the scene, alt kept; the article opens with the original.
        let alt = "Family outside a house including a man, woman with a small child on her hip"
        let html = """
        <html><head><meta property="og:image" content="https://ichef.bbci.co.uk/ace/branded_news/1200/cpsprodpb/7565/live/8d52.jpg"><meta property="og:image:alt" content="\(alt)"></head>
        <body><article><figure><img alt="\(alt)" src="https://ichef.bbci.co.uk/ace/standard/2048/cpsprodpb/45cd/live/c93e.jpg"></figure><p>\(Self.para)</p></article></body></html>
        """
        let doc = try #require(ExtractionDOM.parseDocument(html, baseURI: "https://e.com/story"))
        #expect(ArticlePasses.chooseLead(doc, base: "https://e.com/story") == "https://ichef.bbci.co.uk/ace/standard/2048/cpsprodpb/45cd/live/c93e.jpg")
        // A short or different alt changes nothing.
        let other = html.replacingOccurrences(of: "<img alt=\"\(alt)\"", with: "<img alt=\"Another scene altogether, a long caption\"")
        let doc2 = try #require(ExtractionDOM.parseDocument(other, baseURI: "https://e.com/story"))
        #expect(ArticlePasses.chooseLead(doc2, base: "https://e.com/story") == "https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/7565/live/8d52.jpg")
    }

    @Test func leadsRepeatedInTheBodyStayHidden() {
        // Krebs: the lead is the body's first figure, a paragraph in.
        let krebs = "https://krebsonsecurity.com/wp-content/uploads/2026/10/shutterstock-codeonscreenphp.png"
        #expect(has("<p>\(Self.para)</p><figure><img src=\"\(krebs)\" srcset=\"\(krebs) 974w\"></figure>", krebs))
        // Lenny's #204: the body opens with the player.
        #expect(has("<div><iframe src=\"https://www.youtube-nocookie.com/embed/hnCoQ5wB-GU\"></iframe></div><p>\(Self.para)</p>", "https://e.com/thumb.png"))
        // Simon Willison's Substack: the og crop of the sixth figure.
        let id = "https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F976f74e8-c940-4dab-9335-98325fb003ba_1728x1000.webp"
        #expect(has("<p>\(Self.para)</p><img src=\"https://substackcdn.com/image/fetch/$s_!9tTt!,w_1456,c_limit,f_auto/\(id)\">", "https://substackcdn.com/image/fetch/$s_!9tTt!,w_1200,c_limit,f_jpg/\(id)"))
    }
}
