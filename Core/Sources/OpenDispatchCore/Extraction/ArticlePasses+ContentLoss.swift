import Foundation
import SwiftSoup

/// Passes against article text that goes missing: Readability's scoring and its link-density cleaning of wrapper
/// divs, and our own author-card removal, delete real paragraphs on news sites.
extension ArticlePasses {
    // MARK: keepArticleContent

    /// Page-wide, before Readability (the class names and structure are still the page's).
    static func keepArticleContent(_ root: Element) {
        dropDatabaseWidget(root)
        paragraphBreakSpans(root)
        summaryIntoBody(root)
        dropComponentMeta(root)
        dropNewsletterPrompts(root)
        flattenComponentColumns(root)
        bareTextDivsToParagraphs(root)
    }

    // MARK: Author links in prose

    private static let sentenceEnd = P("[.!?…\"”’')\\]]$")
    /// Share of a paragraph that may be author-page links before it reads as a card, not a sentence with a name in it.
    static let maxProseLinkShare = 0.3
    static let minProseLength = 100

    /// An element that links to an author/people page and is a card (a byline, a bio, a name and a role), not prose that
    /// mentions a person: Smithsonian's "…a London bookseller named <a href=/people/669/>Benjamin Motte</a> with a
    /// manuscript in hand." and TV Insider's links to its /people/ pages are sentences of the story.
    static func hasAuthorCardLink(_ el: Element) -> Bool {
        let links = DOM.select(el, "a[href]").filter { authorHref.test(DOM.attr($0, "href") ?? "") || DOM.attr($0, "rel") == "author" }
        guard !links.isEmpty else { return false }
        let text = DOM.text(el)
        let linked = links.reduce(0) { $0 + DOM.text($1).count }
        let prose = text.count >= minProseLength && sentenceEnd.test(text) && Double(linked) <= maxProseLinkShare * Double(text.count)
            && !isBio(text) && DOM.first(el, "h1, h2, h3, h4, h5, h6, img") == nil
        return !prose
    }

    // MARK: flattenComponentColumns

    private static let componentTags: Set<String> = ["div", "section"]
    private static let proseTags: Set<String> = ["p", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote"]
    private static let blockTags = "div, section, article, p, ul, ol, table, figure, blockquote, h1, h2, h3, h4, h5, h6, pre, aside"
    static let minComponents = 3
    static let minComponentText = 40

    private static func junkWrapper(_ el: Element) -> Bool {
        (DOM.classTokens(el) + [DOM.attr(el, "id") ?? ""]).contains { !$0.isEmpty && (readabilityJunk($0) || sideToken.test($0)) }
    }

    private static func hasOwnText(_ el: Element) -> Bool {
        el.getChildNodes().contains { ($0 as? TextNode).map { !DOM.squash($0.getWholeText()).isEmpty } ?? false }
    }

    /// A paragraph, heading or list, or a div of nothing but text (Apple's `.pagebody-copy`: Readability makes it a <p>).
    private static func isProsePart(_ el: Element) -> Bool {
        if proseTags.contains(DOM.tag(el)) { return true }
        return DOM.tag(el) == "div" && DOM.first(el, blockTags) == nil && DOM.text(el).count >= minComponentText
    }

    /// Where a component's text sits: the component itself or the end of a chain of single-child wrappers below it, when
    /// that holds only paragraphs, headings and lists.
    private static func componentBody(_ component: Element) -> Element? {
        var cur = component
        while componentTags.contains(DOM.tag(cur)), !junkWrapper(cur), !hasOwnText(cur) {
            let kids = DOM.children(cur)
            if kids.isEmpty { return nil }
            if kids.allSatisfy(isProsePart) { return kids.contains { DOM.text($0).count >= minComponentText } ? cur : nil }
            guard kids.count == 1 else { return nil }
            cur = kids[0]
        }
        return nil
    }

    /// A column built of components (BBC's `data-block` text blocks, MLB's story parts, CNBC's `.group` divs, Apple's
    /// `.pagebody` blocks), each wrapping a few paragraphs in layers of divs. Readability's scores thin out through the
    /// layers, so the sibling pass keeps some components and not others, and its link-density cleaning deletes a wrapper
    /// div whose paragraph carries links (MLB's dateline, CNBC's ticker links). With the paragraphs directly in the
    /// column they are scored and kept as a page's own paragraphs are. A column needs three such components.
    static func flattenComponentColumns(_ root: Element) {
        for column in DOM.select(root, "div, section, article, main") {
            guard DOM.isConnected(column), DOM.closest(column, "aside, nav, footer, header, form") == nil,
                  !inComments(column, stop: nil) else { continue }
            let found = DOM.children(column).compactMap { c in componentBody(c).map { (c, $0) } }
            guard found.count >= minComponents else { continue }
            for (component, body) in found {
                for node in Array(body.getChildNodes()) { _ = try? component.before(node) }
                DOM.remove(component)
            }
        }
    }

    private static let metaComponent = P("^(?:(?:single|multi)-)?(?:byline|contributors?)$|^(?:article-)?metadata$|^links$", caseInsensitive: true)

    /// The byline, date strip and related-link cards (`data-block=links`) of a component column, named by its `data-block` / `data-testid` (BBC): with the column
    /// flattened, Readability keeps them as paragraphs of the story.
    static func dropComponentMeta(_ root: Element) {
        for el in DOM.select(root, "[data-block], [data-testid]") where DOM.isConnected(el) {
            if [DOM.attr(el, "data-block"), DOM.attr(el, "data-testid")].contains(where: { $0.map(metaComponent.test) ?? false }) { DOM.remove(el) }
        }
    }

    private static let newsletterPrompt = P("^(?:get this in your inbox first|(?:subscribe|sign up) (?:to|for) (?:the |our )?[^.]{0,60}newsletter)\\b[^.]{0,100}\\.?\\s*$", caseInsensitive: true)

    /// A one-line newsletter prompt ("GET THIS IN YOUR INBOX FIRST: Subscribe to CNBC's "Power Insider" newsletter."). It used to
    /// go with the component wrapper it sat in; with the paragraphs in the column it would stay.
    static func dropNewsletterPrompts(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.text(p).count <= 160 && newsletterPrompt.test(DOM.text(p)) { DOM.remove(p) }
    }

    // MARK: bareTextDivsToParagraphs

    static let maxBareLinkShare = 0.25

    /// A div holding only text and inline markup is a paragraph. Readability turns such divs into <p>s itself, but its
    /// conditional cleaning removes the ones it left (no child element counts as text, so a div with few commas "has no
    /// useful content"): Apple's newsroom keeps its paragraphs in `div.pagebody-copy`, and the first one under each heading,
    /// a short one, went.
    static func bareTextDivsToParagraphs(_ root: Element) {
        for div in DOM.select(root, "div") where DOM.isConnected(div) {
            guard DOM.text(div).count >= minComponentText, DOM.first(div, blockTags) == nil,
                  DOM.first(div, contentMedia) == nil, !junkWrapper(div),
                  DOM.closest(div, "figure, figcaption, aside, nav, footer, header, form, button") == nil else { continue }
            let linked = DOM.select(div, "a[href]").reduce(0) { $0 + DOM.text($1).count }
            guard Double(linked) <= maxBareLinkShare * Double(DOM.text(div).count) else { continue }
            _ = try? div.tagName("p")
        }
    }

    // MARK: paragraphBreakSpans

    private static let breakClass = P("^(?:br|brk|break|line-?break|para(?:graph)?-?break|newline)$", caseInsensitive: true)
    private static let phrasingTags: Set<String> = ["a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "del", "dfn", "em", "i", "ins", "kbd", "mark", "q", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var", "wbr", "br"]

    private static func isBreakSpan(_ node: Node) -> Bool {
        guard let el = node as? Element, DOM.isTag(el, ["span", "i"]), DOM.children(el).isEmpty, DOM.text(el).isEmpty else { return false }
        return DOM.classTokens(el).contains { breakClass.test($0) }
    }

    /// Paragraph breaks drawn as empty spans between bare text (Times of India: `…majority.<span class="id-r-component br">
    /// </span>According to…`). They render as nothing and the sentences run together; each run of text between them
    /// becomes a <p>.
    static func paragraphBreakSpans(_ root: Element) {
        for span in DOM.select(root, "span[class], i[class]") where isBreakSpan(span) && DOM.isConnected(span) {
            guard let parent = span.parent(), DOM.isTag(parent, ["div", "section", "article", "main", "li", "td", "blockquote"]) else { continue }
            var run: [Node] = []
            func flush() {
                defer { run = [] }
                guard run.contains(where: { !DOM.text($0).isEmpty }), let first = run.first, let p = DOM.createElement("p", near: parent) else { return }
                _ = try? first.before(p)
                for n in run { _ = try? p.appendChild(n) }
            }
            for node in Array(parent.getChildNodes()) {
                if isBreakSpan(node) { flush(); DOM.remove(node); continue }
                if let el = node as? Element, !phrasingTags.contains(DOM.tag(el)) || DOM.matches(el, contentMedia) || DOM.first(el, contentMedia) != nil { flush(); continue }
                if node is TextNode || node is Element { run.append(node) }
            }
            flush()
        }
    }

    // MARK: summaryIntoBody

    private static let summaryToken = P("key-?points|story-?summary|key-?takeaways", caseInsensitive: true)
    static let summaryReach = 3
    static let minSummaryBody = 400

    /// A list of key points drawn above the article's body, as its sibling (CNBC's "Key Points", the LA Times'
    /// `data-element=story-summary`): Readability picks the body and leaves it out. It moves to the top of the body.
    static func summaryIntoBody(_ root: Element) {
        func marked(_ el: Element) -> Bool {
            (DOM.classTokens(el) + [DOM.attr(el, "id") ?? "", DOM.attr(el, "data-element") ?? ""]).contains { summaryToken.test($0) }
        }
        for el in DOM.select(root, "div, section, aside, ul, ol") where DOM.isConnected(el) && marked(el) {
            if let p = el.parent(), marked(p) { continue }
            guard !DOM.text(el).isEmpty, DOM.first(el, "li") != nil, DOM.text(el).count <= 1500 else { continue }
            var next = try? el.nextElementSibling()
            var body: Element?
            for _ in 0..<summaryReach {
                guard let cur = next else { break }
                if DOM.proseLen(cur) >= minSummaryBody { body = cur; break }
                next = try? cur.nextElementSibling()
            }
            // Before the first paragraph itself: Readability may pick a block inside the body (CNBC's metered preview).
            guard let body else { continue }
            let lead = DOM.select(body, "p").first { DOM.text($0).count >= minComponentText && DOM.closest($0, "li, blockquote, figure, aside") == nil }
            if let lead { _ = try? lead.before(el) } else { _ = try? body.prependChild(el) }
        }
    }

    // MARK: dropDatabaseWidget

    static let minListedCards = 20
    static let minFooterProse = 500
    static let minIntroProse = 300

    /// An element holding a run of `minListedCards`+ children of one kind, each with some text.
    private static func hasCardList(_ el: Element) -> Bool {
        DOM.select(el, "div, ul, ol, section").contains { list in
            let kids = DOM.children(list)
            guard kids.count >= minListedCards, let tag = kids.first.map(DOM.tag), let cls = kids.first.flatMap({ DOM.classTokens($0).first }) else { return false }
            return kids.allSatisfy { DOM.tag($0) == tag && DOM.classTokens($0).first == cls } && kids.prefix(3).allSatisfy { DOM.text($0).count >= 40 }
        }
    }

    /// The children of text-only wrapper divs, in place of the wrappers, all the way down.
    private static func unwrapDivs(_ el: Element) {
        for child in DOM.children(el) where componentTags.contains(DOM.tag(child)) && !junkWrapper(child) && !hasOwnText(child)
            && DOM.first(child, contentMedia) == nil {
            unwrapDivs(child)
            for node in Array(child.getChildNodes()) { _ = try? child.before(node) }
            DOM.remove(child)
        }
    }

    /// An interactive database inside a story page (ProPublica's 519 detained citizens: filters, sort, pagination and a
    /// card per case). Readability takes the card list as the article, a sample of its longest cards, and the page's own
    /// text around it (the intro above, "How we reported this story" below) is dropped. The widget goes; its filters
    /// are what mark it.
    static func dropDatabaseWidget(_ root: Element) {
        let selects = DOM.select(root, "select[aria-label]")
        guard selects.count >= 2 else { return }
        var widget = selects[0].parent()
        while let w = widget, !(w is Document), !DOM.isTag(w, ["body", "html"]) {
            if DOM.select(w, "select[aria-label]").count >= 2, hasCardList(w) {
                guard DOM.first(w, "h1") == nil else { return }
                var slot = w
                while let p = slot.parent(), DOM.children(p).count == 1, !DOM.isTag(p, ["body", "html"]) { slot = p }
                func adjacent(_ forward: Bool) -> Element? {
                    var cur: Element? = slot
                    while let c = cur, !DOM.isTag(c, ["body", "html"]) {
                        if let sib = (try? forward ? c.nextElementSibling() : c.previousElementSibling()) ?? nil { return sib }
                        cur = c.parent()
                    }
                    return nil
                }
                let before = adjacent(false), after = adjacent(true)
                DOM.remove(slot)
                // The methodology below the widget sits in a `credits-footer` div, which Readability's word list drops.
                for el in DOM.select(root, "div[class*=footer], section[class*=footer]") where DOM.proseLen(el) >= minFooterProse {
                    dropClassTokens(el) { $0.lowercased().contains("footer") }
                    if DOM.attr(el, "id")?.lowercased().contains("footer") == true { DOM.removeAttr(el, "id") }
                }
                // The text above the widget (the intro) joins the text below it, in one flat block: Readability keeps the
                // larger of two blocks.
                if let before, let after, DOM.proseLen(before) >= minIntroProse, DOM.proseLen(after) >= minFooterProse {
                    unwrapDivs(after)
                    unwrapDivs(before)
                    for (i, node) in Array(before.getChildNodes()).enumerated() { _ = try? after.insertChildren(i, [node]) }
                    DOM.remove(before)
                }
                return
            }
            widget = w.parent()
        }
    }

    // MARK: hasUnfilledPrivateContent

    private static let emptyPrivateContent = P("data-private-article-content[^>]*>\\s*(?:<!--[\\s\\S]*?-->\\s*)*</div>", caseInsensitive: true)

    /// Politico (site-specific) serves a story's public half in the page and an empty `data-private-article-content`
    /// element that its scripts fill in with the rest. Extracted from the page alone the story stops after three or four
    /// paragraphs (and the short copy reads as paywalled): the rendered copy has all of it.
    static func hasUnfilledPrivateContent(_ html: String) -> Bool { emptyPrivateContent.test(html) }
}
