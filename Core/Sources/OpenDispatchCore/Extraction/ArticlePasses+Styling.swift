import Foundation
import SwiftSoup

/// Structural leftovers that only show up once the article is drawn by reader.css: summary boxes that lost their card,
/// pull quotes split from their attribution, rules before images, empty spans that split a list, stray leading spaces.
extension ArticlePasses {
    // MARK: Helpers

    private static func isBlank(_ node: Node?) -> Bool {
        (node as? TextNode).map { DOM.squash($0.getWholeText()).isEmpty } ?? false
    }

    private static func textNodes(_ el: Element) -> [TextNode] {
        var out: [TextNode] = []
        func walk(_ n: Node) {
            for c in n.getChildNodes() {
                if let t = c as? TextNode { out.append(t) } else if let e = c as? Element, !DOM.isTag(e, ["script", "style", "pre"]) { walk(e) }
            }
        }
        walk(el)
        return out
    }

    /// The adjacent element, unless text (not just blanks) sits between.
    private static func siblingElement(_ el: Element, forward: Bool) -> Element? {
        var n: Node? = forward ? el.nextSibling() : el.previousSibling()
        while let c = n {
            if let e = c as? Element { return e }
            if let t = c as? TextNode, !DOM.squash(t.getWholeText()).isEmpty { return nil }
            n = forward ? c.nextSibling() : c.previousSibling()
        }
        return nil
    }

    // MARK: tidyStyling

    /// Run from cleanArticle, before tidyFigures (so a figure emptied here goes too).
    static func tidyStyling(_ root: Element) {
        // The sanitizer drops <canvas>; a figure holding only one is an empty box.
        for c in DOM.select(root, "canvas") { DOM.remove(c) }
        for c in DOM.select(root, "figcaption") where !hasMediaOrText(c) { DOM.remove(c) }
        fixControlCharacters(root)
        fixEscapedAmpersands(root)
        keepSpacesOfBlankLinks(root)
        gluedLinks(root)
        trimLeadingSpace(root)
        removeEmptySpans(root)
        separateLinkRuns(root)
        commandLists(root)
        numberedHeadings(root)
        strayPunctuation(root)
        pullQuotes(root)
        tidyRules(root)
        styleCallouts(root)
    }

    // MARK: Characters

    /// cp1252 punctuation that arrived as C1 control characters (U+0092 for ’), which draw as a box.
    private static let cp1252: [UInt32: String] = [
        0x82: "‚", 0x84: "„", 0x85: "…", 0x88: "ˆ", 0x8B: "‹", 0x91: "‘", 0x92: "’", 0x93: "“", 0x94: "”",
        0x95: "•", 0x96: "–", 0x97: "—", 0x98: "˜", 0x99: "™", 0x9B: "›",
    ]

    static func fixControlCharacters(_ root: Element) {
        for t in textNodes(root) {
            let s = t.getWholeText()
            guard s.unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) }) else { continue }
            var out = ""
            for u in s.unicodeScalars {
                if (0x80...0x9F).contains(u.value) { out += cp1252[u.value] ?? "" } else { out.unicodeScalars.append(u) }
            }
            t.text(out)
        }
    }

    private static let escapedAmpersand = P("u0026(?=[A-Za-z_][\\w-]*=)")

    /// A JSON-escaped "&" left in a URL ("?quality=50u0026strip=all").
    static func fixEscapedAmpersands(_ root: Element) {
        for el in DOM.select(root, "img, a, source") {
            for name in ["src", "srcset", "href"] {
                guard let v = DOM.attr(el, name), v.contains("u0026") else { continue }
                DOM.setAttr(el, name, escapedAmpersand.replacing(v, with: "&"))
            }
        }
    }

    // MARK: Spaces

    /// A link holding only a space (`says<a> </a><a>Name</a>`) is a word break; dropped with the link it ran words
    /// together.
    static func keepSpacesOfBlankLinks(_ root: Element) {
        for a in DOM.select(root, "a") where DOM.isConnected(a) {
            let raw = DOM.rawText(a)
            guard !raw.isEmpty, DOM.squash(raw).isEmpty, !hasMediaOrText(a) else { continue }
            DOM.replace(a, with: TextNode(" ", ""))
        }
    }

    private static let sentenceEnding = P("[.!?]$")

    /// "…come months later.<a>See which…</a>": a link that starts a sentence right after the previous one (a button the
    /// page set on its own line) needs the space the layout gave it.
    static func gluedLinks(_ root: Element) {
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) {
            guard let prev = a.previousSibling() as? TextNode, sentenceEnding.test(prev.getWholeText()),
                  let first = DOM.text(a).first, first.isUppercase else { continue }
            prev.text(prev.getWholeText() + " ")
        }
    }

    /// A paragraph or item that starts with a space (a non-breaking one, or one left where an icon was).
    static func trimLeadingSpace(_ root: Element) {
        for block in DOM.select(root, "p, li, h1, h2, h3, h4, h5, h6, td, th, blockquote, figcaption, dt, dd") {
            for t in textNodes(block) {
                // Stop at media or a line break that comes before the first word.
                if precedesText(t, in: block) { break }
                let s = t.getWholeText()
                let trimmed = String(s.drop(while: { $0.isWhitespace || $0 == "\u{00A0}" }))
                if trimmed.count != s.count { t.text(trimmed) }
                if !trimmed.isEmpty { break }
            }
        }
    }

    /// True when an <img>, <br> or the like sits before `t` inside `block`.
    private static func precedesText(_ t: TextNode, in block: Element) -> Bool {
        var cur: Node? = t
        while let c = cur, c !== block {
            var s = c.previousSibling()
            while let n = s {
                if let e = n as? Element, hasMediaOrText(e) || DOM.isTag(e, ["br"]) { return true }
                s = n.previousSibling()
            }
            cur = c.parent()
        }
        return false
    }

    /// An empty <span> between two lists (Axios) splits one list in two, with a gap between.
    static func removeEmptySpans(_ root: Element) {
        for span in DOM.select(root, "span") where DOM.isConnected(span) {
            guard DOM.children(span).isEmpty, DOM.rawText(span).isEmpty else { continue }
            let prev = siblingElement(span, forward: false), next = siblingElement(span, forward: true)
            DOM.remove(span)
            if let a = prev, let b = next, DOM.isTag(a, ["ul", "ol"]), DOM.tag(a) == DOM.tag(b) {
                for c in b.getChildNodes() { _ = try? a.appendChild(c) }
                DOM.remove(b)
            }
        }
    }

    // MARK: Runs of links

    /// Buttons the page laid out as a row or column ("Download weights", "Try in Playground") are bare adjacent links
    /// with nothing between them; run together they read as one blue sentence. Each goes on its own line, and a run
    /// that sits directly in a section is wrapped in a paragraph.
    static func separateLinkRuns(_ root: Element) {
        func button(_ a: Element) -> Bool {
            DOM.tag(a) == "a" && DOM.attr(a, "href") != nil && DOM.textLen(DOM.text(a)) <= 60 && DOM.first(a, contentMedia) == nil
        }
        var seen = Set<ObjectIdentifier>()
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) && !seen.contains(ObjectIdentifier(a)) && button(a) {
            // Start of a run: no link right before it.
            if let p = siblingElement(a, forward: false), DOM.tag(p) == "a" { continue }
            var run = [a]
            while let n = siblingElement(run[run.count - 1], forward: true), button(n) { run.append(n) }
            run.forEach { seen.insert(ObjectIdentifier($0)) }
            guard run.count >= 2, let parent = a.parent(), let last = run.last else { continue }
            // A phrase that merely contains links ("see A, B and C") has text around the run; blocks don't.
            let before = a.previousSibling(), after = last.nextSibling()
            guard before == nil || before is Element || isBlank(before), after == nil || after is Element || isBlank(after) else { continue }
            for l in run.dropFirst() {
                if let br = DOM.createElement("br", near: l) { _ = try? l.before(br) }
            }
            if DOM.isTag(parent, ["div", "section", "body"]), let wrapper = DOM.createElement("p", near: a) {
                _ = try? a.before(wrapper)
                var node: Node? = a
                while let n = node {
                    let next = n.nextSibling()
                    _ = try? wrapper.appendChild(n)
                    if n === last { break }
                    node = next
                }
            }
        }
    }

    // MARK: Command lists

    /// Steps listed as bullets that are nothing but a command (`<ul><li><code>sudo cp …</code></li></ul>`) are code
    /// blocks in the page; as bullets with an inline chip, a long command wraps and its quotes become hard to read.
    static func commandLists(_ root: Element) {
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.children(list).filter { DOM.tag($0) == "li" }
            guard !items.isEmpty else { continue }
            var commands: [String] = []
            for li in items {
                let codes = DOM.select(li, "code")
                guard codes.count == 1, DOM.text(li) == DOM.text(codes[0]) else { break }
                let c = DOM.rawText(codes[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard c.count >= 20, c.contains(" ") else { break }
                commands.append(c)
            }
            guard commands.count == items.count else { continue }
            DOM.replace(list, withHTML: commands.map { "<pre><code>\(DOM.escapeHTML($0))</code></pre>" }.joined())
        }
    }

    // MARK: Numbers before headings

    private static let bareNumber = P("^\\d{1,2}[.)]$")

    /// "<p>1.</p><h3>Question</h3>": a number the page's layout set beside its heading.
    static func numberedHeadings(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) && bareNumber.test(DOM.text(p)) {
            guard let h = siblingElement(p, forward: true), DOM.isTag(h, DOM.headingTags) else { continue }
            _ = try? h.prependChild(TextNode(DOM.text(p) + " ", ""))
            DOM.remove(p)
        }
    }

    // MARK: Orphaned punctuation

    private static let orphanComma = P("[.]\\s+([,;]\\s)")
    private static let orphanDot = P("(?<=[.!?])\\s+[.]\\s*$")

    /// "…active for longer. , and see the report." / "…target-disease pairs. .": a "Read more" button taken out of the
    /// sentence it ended leaves its neighbours' punctuation behind.
    static func strayPunctuation(_ root: Element) {
        func join(_ el: Element) {
            var prev: TextNode?
            for c in el.getChildNodes() {
                if let t = c as? TextNode {
                    if let p = prev { p.text(p.getWholeText() + t.getWholeText()); DOM.remove(t) } else { prev = t }
                } else {
                    prev = nil
                    if let e = c as? Element { join(e) }
                }
            }
        }
        for p in DOM.select(root, "p, li") where DOM.isConnected(p) {
            join(p)
            for t in textNodes(p) {
                let s = t.getWholeText()
                let fixed = orphanComma.replacing(orphanDot.replacing(s, with: "."), with: "$1")
                if fixed != s { t.text(fixed) }
            }
        }
    }

    // MARK: Pull quotes

    private static let attribution = P("\\b(?:said|says|added|wrote|told|noted|explained|continued|stated)\\b", caseInsensitive: true)
    private static let endsMidSentence = P("[,，]\\s*[\"”’']?$")
    private static let endsSentence = P("[.!?…]\\s*[\"”’']?$")
    private static let quoteChars = P("[\"“”‘’'«»]")

    private static func quoteKey(_ s: String) -> String {
        DOM.norm(quoteChars.replacing(s, with: "")).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?…—–-"))
    }

    /// (1) A pull quote whose attribution sits in the next paragraph (`"I blocked them…," Ms Rojas-Valdez said.`) is
    /// one sentence; the attribution joins the quote. (2) A pull quote is the article's own sentence repeated, set in a
    /// figure of its own (`wp-block-pullquote`): when its whole text is in a paragraph, it is that repeat and goes. A
    /// plain blockquote repeating text is a real quotation ("Earlier I said:") and stays.
    static func pullQuotes(_ root: Element) {
        for bq in DOM.select(root, "blockquote") where DOM.isConnected(bq) {
            guard EmbeddedPosts.post(of: bq) == nil, let next = siblingElement(bq, forward: true), DOM.isTag(next, ["p"]),
                  DOM.textLen(DOM.text(next)) <= 80, attribution.test(DOM.text(next)),
                  case let quote = DOM.rawText(bq).trimmingCharacters(in: .whitespacesAndNewlines),
                  endsMidSentence.test(quote) || !endsSentence.test(quote) else { continue }
            let target = DOM.select(bq, "p").last ?? bq
            _ = try? target.appendChild(TextNode(" ", ""))
            for c in next.getChildNodes() { _ = try? target.appendChild(c) }
            DOM.remove(next)
        }
        let figures = DOM.select(root, "figure").filter {
            let kids = DOM.children($0)
            return DOM.isConnected($0) && kids.count == 1 && DOM.tag(kids[0]) == "blockquote"
                && EmbeddedPosts.post(of: kids[0]) == nil && DOM.first($0, "a[href]") == nil
        }
        guard !figures.isEmpty else { return }
        let paragraphs = DOM.select(root, "p, li").filter { DOM.closest($0, "blockquote") == nil }.map { quoteKey(DOM.text($0)) }
        for fig in figures {
            let key = quoteKey(DOM.text(fig))
            if key.count >= 25, paragraphs.contains(where: { $0.contains(key) }) { DOM.remove(fig) }
        }
    }

    // MARK: Rules

    /// A rule is a break between things. One before a picture (a styled divider, a thick rule), one after the last
    /// thing, and the second of two in a row are not.
    static func tidyRules(_ root: Element) {
        func startsWithMedia(_ n: Node?) -> Bool {
            var cur = n as? Element
            while let c = cur {
                if DOM.isTag(c, ["figure", "img", "picture", "video", "iframe"]) { return true }
                let first = c.getChildNodes().first { k in
                    if let t = k as? TextNode { return !DOM.squash(t.getWholeText()).isEmpty }
                    if let e = k as? Element { return hasMediaOrText(e) }
                    return false
                }
                cur = first as? Element
            }
            return false
        }
        for hr in DOM.select(root, "hr") where DOM.isConnected(hr) {
            let next = nextContent(hr, root: root)
            if next == nil || startsWithMedia(next) || (next as? Element).map({ DOM.tag($0) }) == "hr" { DOM.remove(hr) }
        }
    }

    // MARK: Callouts

    private static let calloutLabel = P("^(?:in short|tl;? ?dr|key (?:points|takeaways|facts)|takeaways|at a glance|the short version|quick take|what to know|by the numbers)\\s*:?$", caseInsensitive: true)
    private static let didYouKnow = P("^did you know\\??(?:\\s|$)", caseInsensitive: true)
    private static let noteLabel = P("^(?:note|important|warning|tip|caution|info|heads up)\\s*:?$", caseInsensitive: true)
    static let maxCallout = 1200

    private static func makeCallout(_ el: Element) {
        if DOM.tag(el) != "div" { _ = try? el.tagName("div") }
        DOM.setAttr(el, "class", "x-callout")
    }

    /// A box the page drew as a card (ABC's "In short", Android Authority's "TL;DR", "Did you know?", GitHub-style
    /// "Note" quotes) is recognised by its label, as classes are gone by now: a short container whose first line is the
    /// label, or a label line directly above a list. The reader draws `.x-callout` as a card.
    static func styleCallouts(_ root: Element) {
        for box in DOM.select(root, "div, section, aside, blockquote") where DOM.isConnected(box) && DOM.attr(box, "class") != "x-callout" {
            let kids = DOM.children(box)
            guard kids.count >= 2, let first = kids.first, DOM.isTag(first, ["p", "h2", "h3", "h4", "h5", "h6"]),
                  !box.getChildNodes().contains(where: { ($0 as? TextNode).map { !DOM.squash($0.getWholeText()).isEmpty } ?? false }),
                  DOM.textLen(DOM.text(box)) <= maxCallout, DOM.first(box, "figure, img, iframe, video, table, pre") == nil else { continue }
            let label = DOM.text(first)
            if DOM.tag(box) == "blockquote" {
                if noteLabel.test(label) { makeCallout(box) }
            } else if calloutLabel.test(label) || (DOM.tag(first) == "p" && didYouKnow.test(label)) {
                makeCallout(box)
            }
        }
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            guard let label = siblingElement(list, forward: false), DOM.isTag(label, ["p", "h2", "h3", "h4", "h5", "h6"]),
                  calloutLabel.test(DOM.text(label)), DOM.tag(label.parent() ?? label) != "div" || DOM.attr(label.parent()!, "class") != "x-callout",
                  let card = DOM.createElement("div", near: list) else { continue }
            DOM.setAttr(card, "class", "x-callout")
            _ = try? label.before(card)
            _ = try? card.appendChild(label)
            _ = try? card.appendChild(list)
        }
    }

    // MARK: Before Readability (classes are still there)

    private static let footnoteRef = P("(?:^|[-_ ])(?:foot-?ref|fn-?ref|footnote-?(?:ref|marker|number|link)|note-?ref|fnref|reference-?marker)(?:$|[-_ ])", caseInsensitive: true)

    /// A footnote marker the page drew as a small chip (`<span class="foot-ref">1</span>`) is bare digits once the
    /// class is gone: set it as a superscript.
    static func footnoteMarkers(_ root: Element) {
        for el in DOM.select(root, "span[class]") where DOM.isConnected(el) {
            guard footnoteRef.test(DOM.attr(el, "class") ?? ""), DOM.textLen(DOM.text(el)) <= 4, DOM.first(el, contentMedia) == nil,
                  DOM.closest(el, "sup, a") == nil else { continue }
            _ = try? el.tagName("sup")
        }
    }

    /// A link to an anchor of this page that isn't there (`#procotols-json`; absolutized it would reopen the article)
    /// is plain text.
    static func deadAnchors(_ root: Element, pageURL: String) {
        let page = pageURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pageURL
        var ids: Set<String>?
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) {
            guard let href = DOM.attr(a, "href") else { continue }
            let frag: String
            if href.hasPrefix("#") { frag = String(href.dropFirst()) } else if href.hasPrefix(page + "#") { frag = String(href.dropFirst(page.count + 1)) } else { continue }
            let id = frag.removingPercentEncoding ?? frag
            guard !id.isEmpty else { continue }
            if ids == nil { ids = Set(DOM.select(root, "[id], a[name]").flatMap { [DOM.attr($0, "id"), DOM.attr($0, "name")].compactMap { $0 } }) }
            if ids?.contains(id) == false { _ = try? a.unwrap() }
        }
    }
}
