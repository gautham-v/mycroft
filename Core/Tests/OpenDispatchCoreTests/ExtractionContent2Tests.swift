import Foundation
import Testing
@testable import OpenDispatchCore

/// Text the first rounds still lost: code comments, footnotes, review boxes, collapsible headings, link callouts,
/// galleries, a heading Readability took for the title (the real Readability: needs WebKit, see ExtractionWebKitTests).
@Suite("Extraction: content 2", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionContent2Tests {
    static let para = "The reader shows the whole story, cleanly, without the page around it. The reader shows the whole story, cleanly, without the page around it. The reader shows the whole story, cleanly, without the page around it."
    /// Distinct paragraphs: the same paragraph twice near the top is a teaser and its copy.
    func p(_ n: Int) -> String { "<p>\(Self.para) (part \(n))</p>" }

    func extract(_ html: String, url: String = "https://e.com/story") async throws -> String {
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    @Test @MainActor func commentsInsideACodeBlockSurvive() async throws {
        // Hexo's markup: highlight spans in a <pre> with no <code>, comments as span.comment.
        let html = """
        <html><head><title>Writeup</title></head><body><article><h1>Writeup</h1>\(p(1))
        <figure class="highlight"><pre><span class="line"><span class="comment">// If no source was specified, use the selected one</span></span><br><span class="line"><span class="keyword">if</span> (!params.source) {</span><br><span class="line">  <span class="comment"># it's writable for us</span></span></pre></figure>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("// If no source was specified, use the selected one"))
        #expect(body.contains("# it&#x27;s writable for us") || body.contains("# it's writable for us"))
    }

    @Test @MainActor func aSectionHeadingMadeOfTheTitlesWordsIsKept() async throws {
        let html = """
        <html><head><title>Firefox, Chrome browsers patch 200 security flaws</title></head><body><div class="page-header"><h1>Firefox, Chrome browsers patch 200 security flaws</h1></div><article>\(p(1))
        <h2>Firefox</h2>\(p(2))<h2>Chrome</h2>\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains(">Firefox</h2>"))
        #expect(body.contains(">Chrome</h2>"))
    }

    @Test @MainActor func proseInsideAnUnclosedRelatedBoxIsGivenBack() async throws {
        let cards = (1...3).map { "<div class=\"zd-related-stories__item\"><a href=\"/s\($0)\">Another story number \($0) about something else entirely</a></div>" }.joined()
        let html = """
        <html><head><title>Headphones</title></head><body><article><h1>Headphones</h1>\(p(1))
        <div class="zd-related-stories-flow"><div class="zd-related-stories"><div class="zd-related-stories__title">Trending Now</div>\(cards)</div>
        <p>Auracast is the most popular LE Audio feature, but several other upgrades do not get as much attention. Here is why they matter just as much.</p></div>
        <h2>Better voice quality</h2>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Auracast is the most popular LE Audio feature"))
        #expect(!body.contains("Trending Now"))
    }

    @Test @MainActor func aHeadingInsideACollapsibleButtonIsKept() async throws {
        let html = """
        <html><head><title>Review</title></head><body><article><h1>Review</h1>\(p(1))
        <section><button aria-expanded="true"><h2>Unboxing and Setup</h2><span><svg viewBox="0 0 8 8"><path d="M0 0L8 8"/></svg></span></button><div>\(p(2))</div></section>
        <section><button aria-expanded="true"><h2>Ports and Connectivity</h2><span></span></button><div>\(p(3))</div></section></article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Unboxing and Setup"))
        #expect(body.contains("Ports and Connectivity"))
    }

    @Test @MainActor func prosAndConsAndSpecsBeforeTheArticleJoinIt() async throws {
        let html = """
        <html><head><title>Review</title></head><body><main><h1>Review</h1>
        <section id="pros-cons"><h2>Pros &amp; Cons</h2><ul><li>3,600W output</li><li>Easy to move on wheels</li></ul><ul><li>No 240V output</li></ul></section>
        <section><h2 id="specs">Delta Specs</h2><table><thead><tr><th>Name</th><th>Value</th></tr></thead><tbody><tr><td>Inverter Output</td><td>3600 W</td></tr></tbody></table></section>
        <article>\(p(1))\(p(2))<section><h2>About Our Expert</h2><div><div>Michael Lydick</div><div>Experience</div><p>I am a mechanical engineer with more than thirty years of experience in industrial automation and design.</p></div></section></article></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Pros &amp; Cons"))
        #expect(body.contains("No 240V output"))
        #expect(body.contains("Inverter Output"))
        #expect(!body.contains("About Our Expert"))
        #expect(!body.contains("mechanical engineer"))
    }

    @Test @MainActor func aLabelAndItsDateValueStayTogether() async throws {
        let html = """
        <html><head><title>Review</title></head><body><article><h1>Review</h1>\(p(1))
        <div><ul><li><p>Developer:</p><p>Bandai Namco Aces</p></li><li><p>Release Date:</p><p>October 2, 2026</p></li><li><p>Platforms:</p><p>PS5, PC</p></li></ul></div>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Release Date:</strong> October 2, 2026"))
        #expect(body.contains("Developer:</strong> Bandai Namco Aces"))
    }

    @Test @MainActor func footnotesKeptOutsideTheArticleComeBackWithInPageLinks() async throws {
        let html = """
        <html><head><title>Post</title></head><body><article><h1>Post</h1>\(p(1))
        <p>It launches at the same introductory price <a href="#footnote-1" id="footnote-source-1"><sup>1</sup></a> as before, with cached input priced lower. Distinct tail of this paragraph about prices.</p>\(p(2))\(p(3))</article>
        <uni-footnotes><div id="footnote-1"><a href="#footnote-source-1"><span>1</span></a><div><p><i>After the introductory period expires, the higher price will apply.</i></p></div></div></uni-footnotes></body></html>
        """
        let body = try await extract(html, url: "https://e.com/story")
        #expect(body.contains("After the introductory period expires"))
        #expect(body.contains("href=\"#footnote-1\""))
        #expect(body.contains("id=\"footnote-1\""))
        #expect(!body.contains("e.com/story#footnote"))
    }

    @Test @MainActor func absolutePageLinksToTheArticlesOwnAnchorsStayInThePage() async throws {
        let html = """
        <html><head><title>Post</title></head><body><article><h1>Post</h1>\(p(1))
        <p>A claim.<sup><a href="https://e.com/story#fn1">1</a></sup> More words to make a longer paragraph of distinct text here.</p>\(p(2))
        <ol><li id="fn1">The note itself, with its source named.</li></ol></article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("href=\"#fn1\""))
        #expect(body.contains("id=\"fn1\""))
        #expect(!body.contains("target=\"_blank\" rel=\"noopener noreferrer\">1<"))
    }

    @Test @MainActor func aCloudflareAddressIsDecodedSoItsLineStays() async throws {
        // "info@example.org" with key 0x5f.
        let key: UInt8 = 0x5f
        let hex = String(format: "%02x", key) + "info@example.org".utf8.map { String(format: "%02x", $0 ^ key) }.joined()
        let html = """
        <html><head><title>Podcast</title></head><body><article><h1>Podcast</h1>\(p(1))\(p(2))
        <p>If you have any questions, please email us at <a href="/cdn-cgi/l/email-protection" class="__cf_email__" data-cfemail="\(hex)">[email&#160;protected]</a>. Thanks for listening.</p></article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("mailto:info@example.org"))
        #expect(body.contains("Thanks for listening."))
    }

    @Test @MainActor func aCalloutOfLinksIsNotDroppedForBeingLinks() async throws {
        let html = """
        <html><head><title>Episode</title></head><body><article><h1>Episode</h1>\(p(1))
        <div class="callout-block" data-callout="true"><h4>Blog and detailed workflow walkthroughs from this episode:</h4><p><span>Inside the prototype: </span><a href="https://example.com/how-i-ai/one">https://example.com/how-i-ai/one</a><br><span>Create a draft: </span><a href="https://example.com/how-i-ai/two">https://example.com/how-i-ai/two</a></p></div>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Blog and detailed workflow walkthroughs"))
        #expect(body.contains("https://example.com/how-i-ai/two"))
    }

    @Test @MainActor func aGalleryItemWhoseBlurbHasALinkSurvives() async throws {
        func item(_ n: Int, link: Bool) -> String {
            let blurb = link
                ? "<strong>Adela</strong> made her late-night TV debut performing on <a href=\"https://e.com/shows/fallon\"><em>The Tonight Show Starring Jimmy Fallon</em></a> in New York City on October 22."
                : "Celebrity number \(n) flashed a smile during the curtain call of a Broadway debut in New York City on October 22."
            return "<div class=\"gallery-item\"><div class=\"gallery-item-info\"><div class=\"gallery-item-image-wrap\"><figure><img src=\"https://e.com/p\(n).jpg\" alt=\"\(n)\"></figure><p class=\"gallery-item-credit\"><em>Credit:</em> Photographer \(n)</p><h2>Title \(n)</h2></div><p>\(blurb)</p></div></div>"
        }
        let html = """
        <html><head><title>Hot Pics</title></head><body><article><h1>Hot Pics</h1>\(item(1, link: false))\(item(2, link: true))\(item(3, link: false))\(item(4, link: false))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Title 2"))
        #expect(body.contains("The Tonight Show Starring Jimmy Fallon"))
        #expect(body.contains("href=\"https://e.com/shows/fallon\""))
    }

    @Test @MainActor func itemsOnlyInTheGalleryDataAreAdded() async throws {
        let item1 = #"{"slug":"first","title":"Item One","content":"<p>The first blurb.</p>","credit":"Cred 1","alt":"one","caption":"","image":{"srcset":"/a.jpg?w=100 100w","fallback":"/a.jpg?w=900"}}"#
        let item2 = #"{"slug":"second","title":"Item Two","content":"<p>The second blurb.</p>","credit":"Cred 2","alt":"two","caption":"","image":{"srcset":"/b.jpg?w=100 100w","fallback":"/b.jpg?w=900"}}"#
        let item3 = #"{"slug":"third","title":"Item Three","content":"<p>The third blurb.</p>","credit":"Cred 3","alt":"three","caption":"","image":{"fallback":"/c.jpg?w=900"}}"#
        func dom(_ n: Int, _ slug: String) -> String {
            "<div class=\"gallery-item\" data-slug=\"\(slug)\"><div class=\"gallery-item-info\"><div class=\"gallery-item-image-wrap\"><figure><img src=\"https://e.com/\(slug).jpg\" alt=\"\(slug)\"></figure><p class=\"gallery-item-credit\"><em>Credit:</em> Cred \(n)</p><h2>Item \(n == 1 ? "One" : "Three")</h2></div><p>The \(slug) blurb is the one the page has itself, with enough words to read as a sentence.</p></div></div>"
        }
        let html = """
        <html><head><title>Gallery</title></head><body><article><h1>Gallery</h1>\(p(1))
        <script id="ami-galleries-js-extra">var amiGalleryData = {"items":[\(item1),\(item2),\(item3)],"parent":"x"};
        //# sourceURL=ami-galleries-js-extra</script>
        \(dom(1, "first"))\(dom(3, "third"))\(p(2))</article></body></html>
        """
        let body = try await extract(html)
        let one = try #require(body.range(of: "Item One")), two = try #require(body.range(of: "Item Two")), three = try #require(body.range(of: "Item Three"))
        #expect(one.lowerBound < two.lowerBound && two.lowerBound < three.lowerBound)
        #expect(body.contains("https://e.com/b.jpg?w=900"))
        #expect(body.contains("Cred 2"))
    }

    @Test @MainActor func aHighlightsBoxInAnAsideIsKept() async throws {
        let html = """
        <html><head><title>Models</title></head><body><article><h1>Models</h1>\(p(1))
        <aside class="bg-muted my-9"><h2>Highlights</h2><ul><li><strong>More capability per parameter:</strong> a new architecture allows the small model to beat the previous larger one.</li><li><strong>Every modality, one backbone:</strong> six models trained from the same base model.</li></ul><p>These instances are ideal candidates for specialized intelligence. Enjoy the article.</p></aside>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Highlights"))
        #expect(body.contains("Enjoy the article."))
    }

    @Test @MainActor func aNewsletterAsideIsStillDropped() async throws {
        let html = """
        <html><head><title>News</title></head><body><article><h1>News</h1>\(p(1))
        <aside><h3>Get the inside scoop</h3><p>NEWSLETTER: Or sign up to the royal newsletter here to get all the biggest news and exclusive pictures, straight to your inbox every week.</p></aside>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(!body.contains("sign up to the royal newsletter"))
    }

    @Test @MainActor func aChartDrawnAsRowsOfLinksKeepsItsRows() async throws {
        let rows = ["Smart locks": "17%", "Robot vacuums": "9%", "3D printers": "61%"].sorted { $0.key < $1.key }.map {
            "<div role=\"listitem\"><a href=\"/rankings/\($0.key.lowercased().replacingOccurrences(of: " ", with: "-"))\"><span>\($0.key)</span><span><b>\($0.value)</b></span></a></div>"
        }.joined()
        let html = """
        <html><head><title>Research</title></head><body><article><h1>Research</h1>\(p(1))
        <figure><figcaption>Share of opinions that are negative</figcaption><div role="list">\(rows)</div></figure>\(p(2))\(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Smart locks"))
        #expect(body.contains("3D printers"))
        #expect(body.contains("href=\"https://e.com/rankings/smart-locks\""))
    }

    @Test @MainActor func aSummaryInAHeaderBoxIsTheOpening() async throws {
        let html = """
        <html><head><title>Research</title></head><body><main><article class="info"><header class="info__header"><p>Published Oct 27, 2026</p><h1>Reviewers rarely talk about reliability</h1>
        <div class="info__description"><p>A few weeks ago we compared how negative owners and reviewers are about the same products. This time we looked at what they talk about across many categories and products.</p></div></header>
        <section>\(p(1))\(p(2))</section><section>\(p(3))</section></article></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("A few weeks ago we compared"))
    }

    @Test @MainActor func aTitleHeadingAndItsBylineAreNotRepeated() async throws {
        // No og:title, and a <title> with another wording: the page's own <h1> is the title.
        let html = """
        <html><head><title>Not All Forests Are Equal: Mapping the World's Forests - Site</title></head><body><main>
        <header><h1>Beyond tree cover: mapping the world's forest types</h1><p>Maxim Neumann and Charlotte Stanton</p></header>
        <div>\(p(1))\(p(2))\(p(3))</div></main></body></html>
        """
        let body = try await extract(html)
        #expect(!body.contains("Beyond tree cover"))
        #expect(!body.contains("Maxim Neumann"))
    }
}
