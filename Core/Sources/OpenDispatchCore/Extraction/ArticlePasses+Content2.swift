import Foundation
import SwiftSoup

/// Text the first rounds still lost or mangled: code comments, footnotes, review boxes, collapsible sections, link
/// callouts, galleries, a heading Readability took for the title. Each pass names the pattern it fixes.
extension ArticlePasses {
    /// Before links are absolutized: footnote anchors are still `#id`, and addresses are decoded before any rule
    /// reads them as a placeholder.
    static func prepareContent2(_ root: Element) {
        decodeCloudflareEmails(root)
        gatherFootnotes(root)
        unwrapHeadingButtons(root)
        liftWrappedProse(root)
        dropEmptyVideoSlots(root)
        joinReviewBoxes(root)
        dropAuthorSections(root)
        pcmagVerdict(root)
        joinLabelValueItems(root)
        keepProseAsides(root)
    }

    // MARK: Code comments

    /// Syntax highlighters wrap comments in `span.comment` / `hljs-comment` (Hexo, highlight.js, Pygments). Readability
    /// removes "comment"-classed elements as unlikely candidates unless under a `<code>`, and Hexo's `<pre>` has none, so
    /// every code comment went. Layout words on anything inside a code block are dropped before it runs.
    static func keepCodeClasses(_ root: Element) {
        for el in DOM.select(root, "pre [class], code [class]") {
            dropClassTokens(el) { readabilityJunk($0) && $0 != "hidden" }
        }
    }

    // MARK: Headings Readability takes for the title

    private static let shieldedHeadingAttr = "data-od-heading"

    private static func letters(_ s: String) -> String { DOM.norm(s).filter { $0.isLetter || $0.isNumber } }

    /// Readability removes the first h1/h2 whose words all occur in the page title ("Firefox" in "Firefox, Chrome
    /// browsers patch 200 security flaws…": its text similarity to the title is 1). An h2 that is only some of the
    /// title's words is renamed h3 for its run (`restoreHeadings` puts it back). The h1 is left alone: the headline
    /// region is found from it, and the title rules remove the title's own heading.
    static func shieldTitleWords(_ document: Element) {
        let titles = [DOM.first(document, "meta[property=og:title]").flatMap { DOM.attr($0, "content") }, DOM.first(document, "title").map { DOM.text($0) }]
            .compactMap { $0 }.map(letters).filter { !$0.isEmpty }
        guard !titles.isEmpty else { return }
        for h in DOM.select(document, "h2") {
            let key = letters(DOM.text(h))
            guard key.count >= 3, titles.contains(where: { $0.contains(key) && Double(key.count) < 0.6 * Double($0.count) }) else { continue }
            DOM.setAttr(h, shieldedHeadingAttr, DOM.tag(h))
            _ = try? h.tagName("h3")
        }
    }

    static func restoreHeadings(_ html: String) -> String {
        guard html.contains(shieldedHeadingAttr) else { return html }
        return DOM.withFragment(html) { body -> String in
            for h in DOM.select(body, "[\(shieldedHeadingAttr)]") {
                if let tag = DOM.attr(h, shieldedHeadingAttr) { _ = try? h.tagName(tag) }
                DOM.removeAttr(h, shieldedHeadingAttr)
            }
            return DOM.innerHTML(body)
        } ?? html
    }

    // MARK: Prose inside an unclosed "related" wrapper

    private static let minWrappedProse = 100
    private static let proseEnd = P("[.!?…\"”’')]$")

    /// ZDNet's "Trending Now" box leaves its wrapper (`zd-related-stories-flow`) open, so the paragraph after the cards
    /// is inside it, and Readability drops the wrapper by its "related" class with the paragraph (the article's
    /// intro). A wrapper with a card list and a link-free sentence of its own gives the sentence back to the article.
    static func liftWrappedProse(_ root: Element) {
        for wrap in DOM.select(root, "div[class*=related], div[class*=trending], div[class*=recommend]") where DOM.isConnected(wrap) {
            let kids = DOM.children(wrap)
            guard kids.contains(where: { !DOM.isTag($0, ["p"]) && DOM.select($0, "a[href]").count >= 2 }) else { continue }
            var after: Element = wrap
            for p in kids where DOM.tag(p) == "p" && DOM.first(p, "a, img") == nil
                && DOM.textLen(DOM.text(p)) >= minWrappedProse && proseEnd.test(DOM.text(p)) {
                _ = try? after.after(p)
                after = p
            }
        }
    }

    /// A video slot with only its "More from X" eyebrow (the player is injected by script): nothing to show.
    static func dropEmptyVideoSlots(_ root: Element) {
        for el in DOM.select(root, "[class*=video-player]") where DOM.isConnected(el) && !hasMediaOrText(el) {
            var box: Element = el
            while let p = box.parent(), !(p is Document), DOM.textLen(DOM.text(p)) <= 40, DOM.first(p, "img, video, iframe, picture") == nil,
                  DOM.classTokens(p).contains(where: { $0.contains("video") }) { box = p }
            DOM.remove(box)
        }
    }

    // MARK: Collapsible sections

    /// A collapsible section's title is a `<button>` around the heading and a chevron (PCMag's reviews); cleanup treats
    /// the button as interface and the section runs together without its heading. The heading takes the button's place.
    static func unwrapHeadingButtons(_ root: Element) {
        for button in DOM.select(root, "button") where DOM.isConnected(button) {
            let headings = DOM.select(button, "h1, h2, h3, h4, h5, h6")
            guard headings.count == 1, DOM.textLen(DOM.text(headings[0])) >= 3,
                  DOM.textLen(DOM.text(button)) == DOM.textLen(DOM.text(headings[0])) else { continue }
            DOM.replace(button, with: headings[0])
        }
    }

    // MARK: Review boxes

    private static let reviewBoxHeading = P("^(?:pros(?: ?(?:&|and|/) ?cons)?|cons|[^.:]{0,60} specs?|(?:tech(?:nical)? |key )?specifications?|specs)$", caseInsensitive: true)

    /// A review's verdict box (Pros & Cons, Specs) can sit in sections just before the `<article>` that holds the text
    /// (PCMag), outside what Readability picks. Those sections, each a heading over a list or table, move into it.
    static func joinReviewBoxes(_ root: Element) {
        for article in DOM.select(root, "article") where DOM.isConnected(article) {
            var boxes: [Element] = []
            var sib = try? article.previousElementSibling()
            while let s = sib, DOM.isTag(s, ["section", "div"]),
                  let h = DOM.first(s, "h2, h3"), reviewBoxHeading.test(DOM.text(h)),
                  DOM.first(s, "ul, ol, table") != nil, DOM.textLen(DOM.text(s)) <= 3000 {
                boxes.insert(s, at: 0)
                sib = try? s.previousElementSibling()
            }
            for box in boxes.reversed() { _ = try? article.prependChild(box) }
        }
    }

    private static let aboutAuthor = P("^about (?:the |our |this )?(?:author|expert|writer|reviewer|contributor|editor)s?$", caseInsensitive: true)
    private static let maxBioSection = 2500

    /// An "About Our Expert" / "About the author" section: a bio card (photo, name, years of experience), not the
    /// article. The section goes; a heading with no section of its own takes what follows up to the next heading.
    static func dropAuthorSections(_ root: Element) {
        for h in DOM.select(root, "h2, h3, h4") where DOM.isConnected(h) && aboutAuthor.test(DOM.text(h)) {
            if let section = h.parent(), DOM.isTag(section, ["section", "div"]), DOM.children(section).first === h,
               DOM.textLen(DOM.text(section)) <= maxBioSection, section.parent() != nil, DOM.select(section, "h1, h2, h3, h4, h5, h6").count == 1 {
                // The bio's trailing badges (an Editors' Choice seal) are drawn without a word of text.
                var next = try? section.nextElementSibling()
                DOM.remove(section)
                while let n = next, DOM.text(n).isEmpty, DOM.first(n, "img, video, iframe, picture, table, pre") == nil {
                    next = try? n.nextElementSibling()
                    DOM.remove(n)
                }
                continue
            }
            var next = try? h.nextElementSibling()
            var len = 0
            while let n = next, !DOM.isTag(n, DOM.headingTags) {
                len += DOM.textLen(DOM.text(n))
                next = try? n.nextElementSibling()
            }
            guard len <= maxBioSection else { continue }
            var cur = try? h.nextElementSibling()
            while let n = cur, !DOM.isTag(n, DOM.headingTags) {
                cur = try? n.nextElementSibling()
                DOM.remove(n)
            }
            DOM.remove(h)
        }
    }

    /// PCMag's "Final Thoughts" is a card: the hero photo again, the product name, a score tile with its "What Our
    /// Ratings Mean" tooltip and a GET IT NOW button around the verdict paragraph. Site-specific (`#final-thoughts`).
    static func pcmagVerdict(_ root: Element) {
        guard let h = DOM.first(root, "h2#final-thoughts"), let box = try? h.nextElementSibling(), DOM.tag(box) == "div" else { return }
        for kid in DOM.children(box) where DOM.tag(kid) != "p" || DOM.textLen(DOM.text(kid)) < minWrappedProse { DOM.remove(kid) }
    }

    // MARK: Asides that are the text

    private static let summaryWord = P("summary", caseInsensitive: true)
    private static let asidePitch = P("newsletter|sign up|subscribe|whatsapp|marketing messages|\\babout (?:apple|us|the company)\\b|follow us|download the app", caseInsensitive: true)
    private static let minAsideProse = 200
    private static let maxAsideLinkShare = 0.2

    /// Readability removes every `<aside>` from its result (`_clean(articleContent, "aside")`). A site that sets a
    /// "Highlights" box of the post itself in one (Liquid AI's: a heading, six bullets and the closing paragraph; Surge's
    /// "TL;DR") loses it. An aside in the article holding prose with hardly a link in it, and no sidebar-ish class,
    /// becomes a div (a "summary" class is no reason: it is the box's name), unless it sells something (a newsletter or
    /// WhatsApp pitch, "About <company>") or ends the article with no prose after it.
    static func keepProseAsides(_ root: Element) {
        for aside in DOM.select(root, "article aside, main aside") where DOM.isConnected(aside) {
            guard DOM.closest(aside, "nav, footer, form") == nil,
                  !DOM.classTokens(aside).contains(where: { readabilityJunk($0) || sideToken.test(summaryWord.replacing($0, with: "")) }) else { continue }
            let text = DOM.textLen(DOM.select(aside, "p, li").map { DOM.text($0) }.joined())
            let linked = DOM.select(aside, "a[href]").reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
            guard text >= minAsideProse, Double(linked) <= maxAsideLinkShare * Double(text), !asidePitch.test(DOM.text(aside)) else { continue }
            guard let box = DOM.closest(aside, "article, main"), let last = DOM.select(box, "p").last(where: { DOM.closest($0, "aside") == nil && DOM.textLen(DOM.text($0)) >= minWrappedProse }) else { continue }
            let order = DOM.documentOrder(box)
            guard (order[ObjectIdentifier(last)] ?? 0) > (order[ObjectIdentifier(aside)] ?? 0) else { continue }
            _ = try? aside.tagName("div")
        }
    }

    // MARK: Label and value

    private static let labelText = P("^[^:]{2,40}:$")

    /// A spec list item built as two paragraphs, a label and its value (Kotaku's review box: "Release Date:" over
    /// "October 2, 2026"): one line, "Label: value". As two blocks the value alone reads as a date stamp and went with
    /// its label, and the box fell apart into loose bullets.
    static func joinLabelValueItems(_ root: Element) {
        for li in DOM.select(root, "li") where DOM.isConnected(li) {
            let kids = DOM.children(li)
            guard kids.count == 2, kids.allSatisfy({ DOM.isTag($0, ["p", "div", "span"]) }), labelText.test(DOM.text(kids[0])),
                  DOM.first(li, "ul, ol, figure, img") == nil else { continue }
            let label = DOM.text(kids[0]), value = DOM.innerHTML(kids[1])
            li.empty()
            _ = try? li.append("<strong>\(DOM.escapeHTML(label))</strong> \(value)")
        }
    }

    // MARK: Footnotes

    /// Footnote texts a page keeps outside its article (DeepMind's `<uni-footnotes>` after `</article>`), linked from
    /// superscripts in the text by `#footnote-1`: the superscript stood alone and the note was lost. Each note (what is
    /// at the id, less its "Jump up" link) goes in a list at the end of the article, under the id the superscript
    /// points to, with a link back to it.
    static func gatherFootnotes(_ root: Element) {
        var wanted: [String: Element] = [:]
        for a in DOM.select(root, "a[href^=#]:has(sup), sup > a[href^=#]") {
            guard let href = DOM.attr(a, "href"), href.count > 1 else { continue }
            wanted[String(href.dropFirst())] = a
        }
        guard !wanted.isEmpty else { return }
        var notes: [(id: String, note: Element, ref: Element, article: Element)] = []
        for el in DOM.select(root, "[id]") {
            guard let id = DOM.attr(el, "id"), let ref = wanted[id], let article = DOM.closest(ref, "article, main"),
                  !DOM.contains(article, el), DOM.textLen(DOM.text(el)) >= 5, DOM.textLen(DOM.text(el)) <= 1500 else { continue }
            notes.append((id, el, ref, article))
        }
        guard let article = notes.first?.article else { return }
        var items = ""
        for n in notes where n.article === article {
            let clone = n.note.copy() as? Element ?? n.note
            for a in DOM.select(clone, "a[href^=#]") where DOM.textLen(DOM.text(a)) <= 3 { DOM.remove(a) }
            let back = DOM.attr(n.ref, "id").map { " <a href=\"#\(DOM.escapeAttr($0))\">↩</a>" } ?? ""
            items += "<li id=\"\(DOM.escapeAttr(n.id))\">\(DOM.innerHTML(clone))\(back)</li>"
        }
        guard !items.isEmpty else { return }
        _ = try? article.append("<ol>\(items)</ol>")
    }

    /// An absolutized link to this very page's own anchor is an in-page link (`#footnote-1`): the reader jumps in place
    /// instead of opening the article again. One whose target is not in the article is plain text.
    static func inPageLinks(_ root: Element, base: String?) {
        guard let base else { return }
        let page = base.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? base
        var ids: Set<String>?
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) {
            guard let href = DOM.attr(a, "href") else { continue }
            let frag: String
            if href.hasPrefix(page + "#") { frag = String(href.dropFirst(page.count + 1)) } else if href.hasPrefix("#") { frag = String(href.dropFirst()) } else { continue }
            let id = frag.removingPercentEncoding ?? frag
            guard !id.isEmpty else { continue }
            if ids == nil { ids = Set(DOM.select(root, "[id]").compactMap { DOM.attr($0, "id") }) }
            // A link with no words (a "back to top" icon) stays whole for the rules that remove such links.
            if ids?.contains(id) == true { DOM.setAttr(a, "href", "#" + id) } else if !DOM.text(a).isEmpty { _ = try? a.unwrap() }
        }
    }

    // MARK: Obfuscated e-mail addresses

    private static func cloudflareAddress(_ hex: String) -> String? {
        let digits = Array(hex.utf8)
        guard digits.count >= 4, digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var i = 0
        while i < digits.count {
            guard let b = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        let key = bytes[0]
        let out = String(decoding: bytes.dropFirst().map { $0 ^ key }, as: UTF8.self)
        return out.contains("@") && !out.contains("<") && !out.contains(" ") ? out : nil
    }

    /// Cloudflare hides an address in `data-cfemail` (hex, the first byte the XOR key) and shows "[email protected]". A line
    /// like Quanta's "please email us at …" or Lenny's "Production and marketing by …, email …" was dropped for that
    /// placeholder; with the address back it is a line like any other.
    static func decodeCloudflareEmails(_ root: Element) {
        for el in DOM.select(root, "[data-cfemail]") where DOM.isConnected(el) {
            guard let hex = DOM.attr(el, "data-cfemail"), let address = cloudflareAddress(hex) else { continue }
            let link = "<a href=\"mailto:\(DOM.escapeAttr(address))\">\(DOM.escapeHTML(address))</a>"
            DOM.replace(el, withHTML: DOM.tag(el) == "a" ? link : DOM.escapeHTML(address))
        }
    }

    // MARK: Callouts of links

    /// A callout box (Substack's `callout-block`) is the author's own note, often a labelled list of links ("Blog and
    /// detailed workflow walkthroughs from this episode:"). Readability counts its link text against it and drops
    /// it. A text-only callout that is mostly links is held out like media while Readability runs and put back after
    /// (a product grid's callout, with pictures, is left to Readability).
    static func protectLinkCallouts(_ root: Element, _ saved: inout [String]) {
        for box in DOM.select(root, "[class*=callout]") where DOM.isConnected(box) {
            let text = DOM.textLen(DOM.text(box))
            let linked = DOM.select(box, "a[href]").reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
            guard linked > 0, text <= 1500, Double(linked) >= 0.3 * Double(text), DOM.first(box, contentMedia) == nil,
                  DOM.closest(box.parent() ?? box, "[class*=callout]") == nil,
                  let img = DOM.createElement("img", near: box) else { continue }
            DOM.setAttr(img, "src", "\(placeholder)\(saved.count)")
            DOM.setAttr(img, "alt", "")
            saved.append(DOM.outerHTML(box))
            DOM.replace(box, with: img)
        }
    }

    // MARK: Picture blurbs with a link

    /// Same attribute as `captionLinkAttr`: `unshieldCaptionLinks` turns the spans back into links.
    private static let blurbLinkAttr = "data-od-href"
    private static let blurbSide = P("comment|related|sidebar|footer|nav|menu|teaser|promo|widget|share|recirc|trending|newsletter", caseInsensitive: true)

    /// A picture and a short blurb whose words include a link (a gallery item: "Adéla … on <a>The Tonight Show</a>")
    /// is a box more than a fifth links, and Readability's cleanup removes it with the picture, one item of a gallery
    /// of eighty. The blurb's links wait as spans for the run.
    static func shieldBlurbLinks(_ root: Element) {
        shieldLinkRows(root)
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let total = DOM.textLen(DOM.text(p))
            guard total >= 40, total <= 600 else { continue }
            let links = DOM.select(p, "a[href]")
            let linked = links.reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
            guard !links.isEmpty, Double(linked) > 0.15 * Double(total), Double(linked) <= 0.5 * Double(total) else { continue }
            var box = p.parent()
            var found = false
            var depth = 0
            while let b = box, !(b is Document), depth < 3 {
                if DOM.first(b, "img") != nil { found = true; break }
                box = b.parent()
                depth += 1
            }
            guard found, let top = box, DOM.textLen(DOM.text(top)) <= 1500 else { continue }
            var ancestor: Element? = p
            var side = false
            while let a = ancestor, !(a is Document) {
                if DOM.classTokens(a).contains(where: { blurbSide.test($0) }) { side = true; break }
                ancestor = a.parent()
            }
            guard !side else { continue }
            for link in links {
                guard let href = DOM.attr(link, "href") else { continue }
                DOM.setAttr(link, blurbLinkAttr, href)
                DOM.removeAttr(link, "href")
                _ = try? link.tagName("span")
            }
        }
    }

    /// A chart drawn as rows of links (BettaScore's dumbbell rows: each category a link to its ranking) is nothing but
    /// link text to Readability, which drops the chart with its figure. The row links of a figure with no picture
    /// wait as spans too.
    private static func shieldLinkRows(_ root: Element) {
        for link in DOM.select(root, "figure [role=listitem] a[href], figure li a[href]") where DOM.textLen(DOM.text(link)) > 0 && DOM.closest(link, "figure").map({ DOM.first($0, "img, picture, video") == nil }) == true {
            guard let href = DOM.attr(link, "href") else { continue }
            DOM.setAttr(link, blurbLinkAttr, href)
            DOM.removeAttr(link, "href")
            _ = try? link.tagName("span")
        }
    }

    // MARK: Galleries listed in page data

    /// AMI's gallery pages (Us Weekly's Hot Pics) render the first 80 items and keep the rest, and the page's lead item,
    /// in `amiGalleryData` (picture, credit, title, blurb). Items the page's markup lacks are built the way it builds
    /// its own and put in order among them.
    static func placeGalleryItems(_ document: Element, base: String) {
        guard let script = DOM.first(document, "script#ami-galleries-js-extra"),
              let items = galleryItems(script.data()) else { return }
        let present = DOM.select(document, ".gallery-item[data-slug]")
        guard !present.isEmpty else { return }
        var bySlug: [String: Element] = [:]
        for el in present { if let slug = DOM.attr(el, "data-slug") { bySlug[slug] = el } }
        var anchor: Element?
        for item in items {
            guard let slug = item["slug"] as? String, let title = item["title"] as? String else { continue }
            if let el = bySlug[slug] { anchor = el; continue }
            let html = galleryItemHTML(item, slug: slug, title: title, base: base)
            if let anchor { _ = try? anchor.after(html) } else { _ = try? present[0].before(html) }
            anchor = DOM.first(document, ".gallery-item[data-slug=\"\(slug)\"]") ?? anchor
        }
    }

    private static func galleryItems(_ script: String) -> [[String: Any]]? {
        guard let start = script.range(of: "amiGalleryData = ")?.upperBound, let end = script.lastIndex(of: "}") else { return nil }
        let json = String(script[start...end])
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["items"] as? [[String: Any]]
    }

    private static func galleryItemHTML(_ item: [String: Any], slug: String, title: String, base: String) -> String {
        func abs(_ s: String?) -> String? { DOM.absURL(s, base: base) }
        let image = item["image"] as? [String: Any]
        var picture = ""
        if let src = abs(image?["fallback"] as? String) {
            let srcset = (image?["srcset"] as? String).map { set in
                ArticlePasses.parseSrcset(set).compactMap { c in abs(c.url).map { [$0, c.descriptor].filter { !$0.isEmpty }.joined(separator: " ") } }.joined(separator: ", ")
            }
            picture = "<figure class=\"gallery-img\"><img src=\"\(DOM.escapeAttr(src))\"\(srcset.map { " srcset=\"\(DOM.escapeAttr($0))\"" } ?? "") alt=\"\(DOM.escapeAttr(item["alt"] as? String ?? ""))\"></figure>"
        }
        let credit = (item["credit"] as? String).flatMap { $0.isEmpty ? nil : "<p class=\"gallery-item-credit\"><em>Credit:</em> \(DOM.escapeHTML($0))</p>" } ?? ""
        let caption = (item["caption"] as? String).flatMap { $0.isEmpty ? nil : "<div class=\"gallery-item-image-caption\">\($0)</div>" } ?? ""
        let content = item["content"] as? String ?? ""
        return "<div class=\"gallery-item\" data-slug=\"\(DOM.escapeAttr(slug))\"><div class=\"gallery-item-info\"><div class=\"gallery-item-image-wrap\">\(picture)\(credit)\(caption)<h2>\(DOM.escapeHTML(title))</h2></div>\(content)</div></div>"
    }

    // MARK: A dek that is the opening

    private static let sentenceBreak = P("[.!?][\"”’)]?\\s+\\p{Lu}")

    /// A page's summary under the headline, in a `header`-classed box (BettaScore's `bs-info__header`): Readability's
    /// word lists remove the box with the opening paragraph in it. A paragraph of two sentences or more (not a
    /// one-line dek) right after the headline in such a box keeps its box's "header" words to itself.
    static func keepHeaderOpening(_ document: Element) {
        guard let h1 = ArticleExtraction.headline(document), let box = h1.parent(), !(box is Document), !DOM.isTag(box, ["body", "html"]) else { return }
        let paras = DOM.select(box, "p").filter { DOM.closest($0, "h1") == nil }
        guard let p = paras.first(where: { DOM.textLen(DOM.text($0)) >= 150 }), sentenceBreak.test(DOM.text(p)), DOM.textLen(DOM.text(box)) <= 1500 else { return }
        var el: Element? = p
        while let e = el, !(e is Document), !DOM.isTag(e, ["body", "html"]) {
            dropClassTokens(e) { readabilityJunk($0) && $0 != "hidden" }
            if e === box { break }
            el = e.parent()
        }
        if let up = box.parent() { dropClassTokens(up) { readabilityJunk($0) && $0 != "hidden" } }
    }
}
