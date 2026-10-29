import Foundation
import SwiftSoup

/// Captions and styling the first rounds left (the second audit): words under a picture that read as body text, credits
/// outside their caption or said twice, galleries drawn as bulleted lists, emphasis set by inline style, bullets typed as
/// "•" lines, a bold heading ending in a parenthesis, a table's header row of bold cells, and the lead picture's caption.
/// `preparePolish2` runs at the start of `prepare` (while comments and inline styles are still there); `polish2` runs
/// from cleanArticle after tidyCaptions.
extension ArticlePasses {
    static func preparePolish2(_ root: Element) {
        dropComments(root)
        inlineStyleEmphasis(root)
        visibleCaptions(root)
    }

    static func polish2(_ root: Element) {
        pictureLists(root)
        captionsAfterPictures(root)
        wordsIntoCaptions(root)
        repeatedFigures(root)
        flattenCaptionBlocks(root)
        repeatedCredits(root)
        bulletParagraphs(root)
        parentheticalHeadings(root)
        headerRows(root)
        fixMojibake(root)
    }

    private static func polishTextNodes(_ el: Element) -> [TextNode] {
        var out: [TextNode] = []
        var stack: [Node] = [el]
        while let n = stack.popLast() {
            if let t = n as? TextNode { out.append(t) } else { stack.append(contentsOf: n.getChildNodes().reversed()) }
        }
        return out
    }

    // MARK: Comments

    /// React's server rendering separates adjacent text with `<!-- -->` ("Principal Engineer<!-- -->, <!-- -->PGA
    /// America"). Readability wraps runs of phrasing content in paragraphs and a comment ends a run, so one line became
    /// three paragraphs, one of them a lone comma. After resolveStreamedBoundaries, which reads `<!--/$-->`.
    static func dropComments(_ root: Element) {
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            for child in node.getChildNodes() {
                if child is Comment { DOM.remove(child) } else if child is Element { stack.append(child) }
            }
        }
    }

    // MARK: Inline-style emphasis

    private static let boldStyle = P("font-weight\\s*:\\s*(?:bold|bolder|[6-9]00)\\b", caseInsensitive: true)
    private static let italicStyle = P("font-style\\s*:\\s*italic\\b", caseInsensitive: true)
    private static let normalWeight = P("font-weight\\s*:\\s*(?:normal|[1-4]00)\\b", caseInsensitive: true)
    private static let emphasisBlocks = "p, div, ul, ol, li, table, figure, blockquote, h1, h2, h3, h4, h5, h6, section, article"
    static let maxStyledRun = 300

    /// Rich-text editors (Blogger, Google Docs pastes) set bold and italic as `<span style="font-weight: bold">`, and
    /// Readability strips style attributes, so "Alternative Policies We Considered" lost the weight that made it a
    /// heading and the italic run-ins went plain. They become <strong> and <em> (promoteBoldHeadings then sees the
    /// heading). Google Docs' `<b style="font-weight:normal">` around a whole paste is no bold at all: unwrapped.
    static func inlineStyleEmphasis(_ root: Element) {
        for b in DOM.select(root, "b[style], strong[style]") where normalWeight.test(DOM.attr(b, "style") ?? "") {
            _ = try? b.unwrap()
        }
        for span in DOM.select(root, "span[style], font[style]") where DOM.isConnected(span) {
            let style = DOM.attr(span, "style") ?? ""
            let bold = boldStyle.test(style) && DOM.closest(span, "b, strong, h1, h2, h3, h4, h5, h6, th") == nil
            let italic = italicStyle.test(style) && DOM.closest(span, "em, i") == nil
            guard bold || italic else { continue }
            let words = DOM.text(span)
            guard !words.isEmpty, words.count <= maxStyledRun, DOM.first(span, emphasisBlocks) == nil else { continue }
            // The span itself becomes the tag, so a paragraph that is only this run is only a <strong>.
            if bold && italic, let em = DOM.createElement("em", near: span) {
                for child in span.getChildNodes() { _ = try? em.appendChild(child) }
                _ = try? span.appendChild(em)
            }
            _ = try? span.tagName(bold ? "strong" : "em")
            DOM.removeAttr(span, "style")
        }
    }

    // MARK: Hidden captions

    /// El País marks its <figcaption> aria-hidden (the alt text already says it), so Readability drops the caption
    /// the page shows under every photo. One with words and no hiding style is visible.
    static func visibleCaptions(_ root: Element) {
        for cap in DOM.select(root, "figcaption[aria-hidden=true]") where !DOM.text(cap).isEmpty && DOM.attr(cap, "style") == nil {
            DOM.removeAttr(cap, "aria-hidden")
        }
    }

    // MARK: Picture lists

    static let maxListItemWords = 200

    /// A carousel or gallery marked up as a list (Android Police's `<ul><li><p><img>`, Vogue's and GQ's slides): each
    /// picture got a bullet beside it and an indent, and an empty slide an empty bullet. A list whose items are all a
    /// picture, with no more than a caption besides, is a run of pictures.
    static func pictureLists(_ root: Element) {
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.children(list)
            guard items.allSatisfy({ DOM.isTag($0, ["li"]) }) else { continue }
            let full = items.filter { hasMediaOrText($0) }
            guard !full.isEmpty, full.allSatisfy(isPictureItem) else { continue }
            for li in items {
                if hasMediaOrText(li) { for child in li.getChildNodes() { _ = try? list.before(child) } }
            }
            DOM.remove(list)
        }
    }

    private static func isPictureItem(_ li: Element) -> Bool {
        guard DOM.first(li, "img, picture, video") != nil,
              DOM.first(li, "ul, ol, table, pre, blockquote, iframe, h1, h2, h3, h4, h5, h6") == nil else { return false }
        // Words outside a caption: a short line at most, and not a link (a product tile's name and shop link).
        var outside = 0
        for t in polishTextNodes(li) where DOM.closest(t.parent() as? Element ?? li, "figcaption") == nil {
            let s = DOM.squash(t.getWholeText())
            guard !s.isEmpty else { continue }
            if let parent = t.parent() as? Element, DOM.closest(parent, "a") != nil { return false }
            outside += s.count
        }
        return outside <= maxListItemWords
    }

    // MARK: Captions after pictures

    /// A credit by its wording: "Photo: …", "Photograph by …", "Credit: …", "Courtesy of …", "©", an agency after a
    /// slash or "via", or "Name / Outlet" (Android Authority's "Brady Snyder / Android Authority").
    private static let creditWords = P("^(?:(?:photo(?:graph)?s?|photo-illustration|illustration|image|picture|video|footage|credit|source)s?\\s*(?::|by\\b)|courtesy\\b|©|\\(c\\))|\\b(?:via|/)\\s*(?:getty|shutterstock|reuters|ap\\b|afp|unsplash|alamy|epa\\b|bloomberg|imago|picture alliance|dpa\\b)", caseInsensitive: true)
    private static let nameSlashOutlet = P("^\\p{Lu}[\\p{L}.'’ -]{1,40} / \\p{Lu}[\\p{L}&.'’ -]{1,40}$")
    private static let notACaption = P("\\baffiliate\\b|\\bcommission\\b|\\bsubscribe\\b", caseInsensitive: true)
    static let maxCredit = 120
    static let maxLooseCaption = 300

    static func isCredit(_ s: String) -> Bool {
        s.count <= maxCredit && (creditWords.test(s) || nameSlashOutlet.test(s))
    }

    /// The words a page sets right under a picture outside any <figure> read as the next paragraph of the story: the
    /// alt text repeated as a line (Times Now's cover image), a paragraph in <small> (PCMag's "… (Credit: Michael
    /// Lydick)"), or a credit (Vogue's "Photo: Courtesy of …", Android Authority's "Name / Android Authority"). The
    /// picture and its words become a <figure> with a <figcaption>.
    static func captionsAfterPictures(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            guard DOM.closest(img, "figure, figcaption, li, td, th, blockquote") == nil, !isTinyImg(img) else { continue }
            // The largest wrapper that is only this picture.
            var top: Element = img
            while let p = top.parent(), p !== root, DOM.text(p).isEmpty, DOM.select(p, "img").count == 1,
                  DOM.first(p, "video, iframe, svg, audio, table, canvas") == nil { top = p }
            guard let next = nextElementBlock(top), let words = looseCaption(next, alt: DOM.attr(img, "alt")) else { continue }
            let picture = DOM.closest(img, "picture").flatMap { DOM.contains(top, $0) ? $0 : nil } ?? img
            guard let fig = DOM.createElement("figure", near: top), let cap = DOM.createElement("figcaption", near: top) else { continue }
            _ = try? cap.text(words)
            _ = try? top.before(fig)
            _ = try? fig.appendChild(picture)
            _ = try? fig.appendChild(cap)
            DOM.remove(top)
            DOM.remove(next)
        }
    }

    /// The element right after `el`, unless words sit between.
    private static func nextElementBlock(_ el: Element) -> Element? {
        var n = el.nextSibling()
        while let cur = n {
            if let e = cur as? Element { return e }
            if let t = cur as? TextNode, !DOM.squash(t.getWholeText()).isEmpty { return nil }
            n = cur.nextSibling()
        }
        return nil
    }

    private static func looseCaption(_ el: Element, alt: String?) -> String? {
        guard DOM.isTag(el, ["p", "div", "span", "small", "em", "i"]), DOM.first(el, contentMedia) == nil,
              DOM.first(el, "ul, ol, table, blockquote, h1, h2, h3, h4, h5, h6, a[href], figure") == nil else { return nil }
        let words = DOM.text(el)
        guard !words.isEmpty, words.count <= maxLooseCaption, !notACaption.test(words) else { return nil }
        if let alt, DOM.norm(alt) == DOM.norm(words) { return words }
        let small = DOM.select(el, "small").map { DOM.text($0) }.joined(separator: " ")
        if DOM.squash(small) == words { return words }
        return isCredit(words) ? words : nil
    }

    // MARK: Words in a figure outside its caption

    static let maxStrayCredit = 150

    /// A credit a figure keeps beside its picture rather than in its caption: BBC's copyright span next to the image
    /// (in a figure with no caption), HuffPost's credit block after the <figcaption>. It drew as a body-sized line in
    /// the figure; it joins the caption, or becomes it.
    static func wordsIntoCaptions(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            let caps = DOM.select(fig, "figcaption")
            guard caps.count <= 1, DOM.first(fig, "img, picture") != nil,
                  DOM.first(fig, "iframe, table, pre, blockquote, ul, ol, svg, audio, h1, h2, h3, h4, h5, h6") == nil,
                  DOM.first(fig, "figure") == nil else { continue }
            // Words after the picture only: a dek set above it (The Ringer's) is not its credit.
            var stray: [Node] = []
            var pictured = false
            func collect(_ el: Element) {
                for child in el.getChildNodes() {
                    if let t = child as? TextNode {
                        if pictured, !DOM.squash(t.getWholeText()).isEmpty { stray.append(t) }
                    } else if let c = child as? Element {
                        if DOM.isTag(c, ["figcaption"]) { continue }
                        if DOM.matches(c, contentMedia) { pictured = true; continue }
                        if DOM.first(c, contentMedia) != nil || DOM.first(c, "figcaption") != nil { collect(c) } else if pictured, !DOM.text(c).isEmpty { stray.append(c) }
                    }
                }
            }
            collect(fig)
            // A note with a link ("Interactive figure not shown here. View it…") keeps its link where it is.
            guard !stray.isEmpty, !stray.contains(where: { ($0 as? Element).map { DOM.first($0, "a[href]") != nil || DOM.tag($0) == "a" } ?? false }) else { continue }
            let words = DOM.squash(stray.map { DOM.text($0) }.joined(separator: " "))
            guard words.count <= maxStrayCredit, !notACaption.test(words) else { continue }
            stray.forEach(DOM.remove)
            if let cap = caps.first {
                let existing = DOM.text(cap)
                if !existing.contains(words) { _ = try? cap.append(" " + DOM.escapeHTML(words)) }
            } else {
                _ = try? fig.append("<figcaption>\(DOM.escapeHTML(words))</figcaption>")
            }
        }
    }

    /// The same picture with the same caption twice (Vulture's header art, once in the page header and once as the
    /// body's first block, the second only now a figure): once is enough.
    static func repeatedFigures(_ root: Element) {
        var seen: Set<String> = []
        // A figure wrapping a figure (Quanta's) is one picture, not two: only innermost figures count.
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) && DOM.first(fig, "figure") == nil {
            guard let img = DOM.first(fig, "img"), let src = DOM.attr(img, "src"), let cap = DOM.first(fig, "figcaption"),
                  !DOM.text(cap).isEmpty else { continue }
            if !seen.insert(src + "|" + DOM.text(cap)).inserted { DOM.remove(fig) }
        }
    }

    // MARK: Caption blocks

    private static let slideCounter = P("^\\d{1,3}\\s*/\\s*\\d{1,3}$")
    private static let blockTagNames: Set<String> = ["p", "div", "section", "header", "footer"]

    /// Condé Nast's gallery captions are blocks: the credit, a "3/35" slide counter, then the caption, each its own
    /// line with paragraph spacing (and the counter only on some slides). The counter goes, the credit follows the
    /// caption, and the parts run as one caption.
    static func flattenCaptionBlocks(_ root: Element) {
        for cap in DOM.select(root, "figcaption") where DOM.isConnected(cap) {
            let leaves = DOM.select(cap, "p, div").filter { DOM.first($0, "p, div") == nil && !DOM.text($0).isEmpty }
            guard leaves.count >= 2 || leaves.contains(where: { slideCounter.test(DOM.text($0)) }) else { continue }
            // A caption with its own heading (E! Online's slide titles) is laid out on purpose.
            guard DOM.first(cap, contentMedia) == nil, DOM.first(cap, "h1, h2, h3, h4, h5, h6, ul, ol") == nil else { continue }
            var parts = leaves.filter { !slideCounter.test(DOM.text($0)) && !noWordsLeft.test(DOM.text($0)) }
            if parts.count >= 2, isCredit(DOM.text(parts[0])) || agencyCredit.test(DOM.text(parts[0])) { parts.append(parts.removeFirst()) }
            // Words of the caption outside any block (a bare text run) are kept in order before the blocks.
            let loose = cap.getChildNodes().filter { ($0 as? TextNode).map { !DOM.squash($0.getWholeText()).isEmpty } ?? false }
            var nodes: [Node] = loose
            for (i, block) in parts.enumerated() {
                if i > 0 || !loose.isEmpty { nodes.append(TextNode(" ", "")) }
                nodes.append(contentsOf: block.getChildNodes())
            }
            for child in cap.getChildNodes() { DOM.remove(child) }
            for n in nodes { _ = try? cap.appendChild(n) }
        }
    }

    private static let noWordsLeft = P("^[.…,;:\\s]*$")
    /// "Stefanie Keenan/Getty Images": a name and an agency.
    private static let agencyCredit = P("^[^/]{2,60}/\\s*(?:getty|shutterstock|reuters|ap\\b|afp|alamy|epa\\b|bloomberg|[\\p{L} ]{2,30}$)", caseInsensitive: true)

    // MARK: Repeated credits

    private static let creditFiller: Set<String> = ["via", "and", "the", "for", "photo", "photos", "by", "courtesy", "of"]
    private static let wordSplit = P("[^\\p{L}\\p{N}]+")
    private static let spacedColon = P("\\b(Credit|Photo|Image|Source)\\s+:")

    /// Cleveland.com writes the credit in the caption ("(Photo by Smith Collection/Gado/Getty Images)") and again in a
    /// credit span after it ("Gado via Getty Images"); People's "Credit :" has a space before its colon.
    static func repeatedCredits(_ root: Element) {
        func words(_ s: String) -> [String] {
            wordSplit.replacing(s.lowercased(), with: " ").split(separator: " ").map(String.init)
        }
        for cap in DOM.select(root, "figcaption") {
            for t in polishTextNodes(cap) where spacedColon.test(t.getWholeText()) { t.text(spacedColon.replacing(t.getWholeText(), with: "$1:")) }
            let full = DOM.text(cap)
            for el in DOM.select(cap, "span, small, em, i, cite") where DOM.isConnected(el) {
                let credit = DOM.text(el)
                guard !credit.isEmpty, credit.count <= maxCredit, full.hasSuffix(credit), full.count > credit.count * 2 else { continue }
                let before = Set(words(String(full.dropLast(credit.count))))
                let own = words(credit).filter { $0.count >= 3 && !creditFiller.contains($0) }
                if !own.isEmpty, own.allSatisfy({ before.contains($0) }) { DOM.remove(el) }
                break
            }
        }
    }

    // MARK: Bullet lines

    private static let bulletStart = P("^[\\s\\u00A0]*[•●▪◦][\\s\\u00A0]+")

    /// The Athletic types its lists as "• " lines in a paragraph (`<p>• The Steelers traded…<br>• The Rams…</p>`), or
    /// one "• " paragraph per item: no hanging indent, and the lines wrap under the bullet. They become a list.
    static func bulletParagraphs(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            var lines: [[Node]] = [[]]
            for child in p.getChildNodes() {
                if let e = child as? Element, DOM.tag(e) == "br" { lines.append([]) } else { lines[lines.count - 1].append(child) }
            }
            let items = lines.filter { line in line.contains { !DOM.text($0).isEmpty || (($0 as? Element).map { DOM.matches($0, contentMedia) } ?? false) } }
            guard !items.isEmpty, items.allSatisfy({ line in
                guard let first = line.first(where: { !DOM.squash(DOM.rawText($0)).isEmpty }) else { return false }
                return bulletStart.test(DOM.rawText(first))
            }) else { continue }
            guard let list = DOM.createElement("ul", near: p) else { continue }
            for line in items {
                guard let li = DOM.createElement("li", near: p) else { continue }
                var stripped = false
                for n in line {
                    if !stripped, !DOM.squash(DOM.rawText(n)).isEmpty {
                        stripped = true
                        stripBullet(n)
                    }
                    _ = try? li.appendChild(n)
                }
                _ = try? list.appendChild(li)
            }
            // One "• " paragraph per item: the items join the list just before.
            if let prev = try? p.previousElementSibling(), DOM.tag(prev) == "ul", DOM.attr(prev, "data-bullets") == "1",
               p.previousSibling().map({ $0 === prev || DOM.squash(DOM.rawText($0)).isEmpty }) ?? false {
                for li in DOM.children(list) { _ = try? prev.appendChild(li) }
                DOM.remove(p)
            } else {
                DOM.setAttr(list, "data-bullets", "1")
                DOM.replace(p, with: list)
            }
        }
        for list in DOM.select(root, "ul[data-bullets]") { DOM.removeAttr(list, "data-bullets") }
    }

    /// Removes the leading "• " from the first text of `node`.
    private static func stripBullet(_ node: Node) {
        if let t = node as? TextNode {
            t.text(bulletStart.replacing(t.getWholeText(), with: ""))
        } else if let e = node as? Element, let t = polishTextNodes(e).first(where: { !DOM.squash($0.getWholeText()).isEmpty }) {
            t.text(bulletStart.replacing(t.getWholeText(), with: ""))
        }
    }

    // MARK: Parenthetical headings

    private static let parentheticalHeading = P("^[^.!?:;()]{1,50}\\([^()]{1,30}\\)$")

    /// promoteBoldHeadings leaves a bold line ending in ")" alone (a credit, a sentence); "Defense (opponent)" above
    /// its stat lines is a heading like the "Offense" before it (The Athletic), so the two groups match.
    static func parentheticalHeadings(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let kids = p.getChildNodes().filter { !(($0 as? TextNode).map { DOM.squash($0.getWholeText()).isEmpty } ?? false) }
            guard kids.count == 1, let bold = kids.first as? Element, DOM.isTag(bold, ["b", "strong"]), DOM.children(bold).isEmpty else { continue }
            let t = DOM.text(bold)
            guard parentheticalHeading.test(t), let next = try? p.nextElementSibling(), DOM.isTag(next, ["p", "ul", "ol"]),
                  let h = DOM.createElement("h3", near: p) else { continue }
            _ = try? h.text(t)
            DOM.replace(p, with: h)
        }
    }

    // MARK: Header rows

    /// A table whose first row is bold cells (VentureBeat's pricing table: `<td><p><b>Model</b></p></td>`) has a header
    /// row the page drew with bold, not <th>; it becomes one so it reads as the header. A cell holding one paragraph
    /// loses the paragraph's margins.
    static func headerRows(_ root: Element) {
        for table in DOM.select(root, "table") where DOM.first(table, "th, thead") == nil {
            guard let row = DOM.first(table, "tr") else { continue }
            let cells = DOM.children(row)
            guard cells.count >= 2, cells.allSatisfy({ DOM.isTag($0, ["td"]) }), cells.contains(where: { !DOM.text($0).isEmpty }),
                  cells.allSatisfy({ cell in
                      let all = DOM.text(cell)
                      return all.isEmpty || DOM.squash(DOM.select(cell, "b, strong").map { DOM.text($0) }.joined(separator: " ")) == all
                  }) else { continue }
            // A single bold row is a table of one row, not a header.
            guard DOM.select(table, "tr").count >= 2 else { continue }
            for cell in cells {
                _ = try? cell.tagName("th")
                for b in DOM.select(cell, "b, strong") { _ = try? b.unwrap() }
            }
            if let body = row.parent(), DOM.isTag(body, ["tbody"]), let head = DOM.createElement("thead", near: row) {
                _ = try? body.before(head)
                _ = try? head.appendChild(row)
            }
        }
        for cell in DOM.select(root, "td, th") {
            let kids = cell.getChildNodes().filter { !(($0 as? TextNode).map { DOM.squash($0.getWholeText()).isEmpty } ?? false) }
            if kids.count == 1, let p = kids.first as? Element, DOM.tag(p) == "p" { _ = try? p.unwrap() }
        }
    }

    // MARK: Mojibake

    /// UTF-8 read as Windows-1252, as the page itself shows it (the New York Post's "Â©Warner Bros"): "Â" before a
    /// Latin-1 symbol, and "â€" before the second half of a curly quote or dash.
    private static let latin1Pair = P("Â([\\u00A0-\\u00BF])")
    private static let cp1252Triples: [(String, String)] = [
        ("â€™", "’"), ("â€˜", "‘"), ("â€œ", "“"), ("â€\u{9D}", "”"), ("â€”", "—"), ("â€“", "–"), ("â€¦", "…"),
    ]

    static func fixMojibake(_ root: Element) {
        for t in polishTextNodes(root) {
            let s = t.getWholeText()
            guard s.contains("Â") || s.contains("â€") else { continue }
            var out = latin1Pair.replacing(s, with: "$1")
            for (bad, good) in cp1252Triples { out = out.replacingOccurrences(of: bad, with: good) }
            if out != s { t.text(out) }
        }
    }

    // MARK: Lead caption

    static let maxLeadCaption = 600

    /// The page's lead picture with its caption, when the body doesn't show it: the reader draws the lead above the
    /// body without words, so the caption and credit under the page's hero (Al Jazeera, Business Insider, The
    /// Guardian, Le Monde, The Japan Times…) were lost. The hero <figure> goes first in the body, which the reader
    /// then shows in place of its own copy (`LeadImage.contentHasHero`). Only a figure holding the lead's own file,
    /// so a different crop never doubles the picture; a paragraph in the body repeating the caption goes.
    static func leadCaption(_ html: String, document: Element, lead: String?) -> String {
        guard let lead, !LeadImage.contentHasHero(html, hero: lead) else { return html }
        for fig in DOM.select(document, "figure") {
            guard let cap = DOM.first(fig, "figcaption"), let img = DOM.first(fig, "img"), !isTinyImg(img),
                  let src = DOM.attr(img, "src"), src.hasPrefix("http"), !html.contains(src) else { continue }
            let words = dropRepeatedTail(captionText(cap))
            guard !words.isEmpty, words.count <= maxLeadCaption else { continue }
            // Checked beside the body's pictures, so a folder id they all share (Webflow's site id) names nothing.
            // A sharing card counts as any picture of its site in contentHasHero; here it must name the same file.
            guard LeadImage.contentHasHero("<img src=\"\(DOM.escapeAttr(src))\">" + html, hero: lead),
                  !LeadImage.isCardLike(lead) || !LeadImage.keys(src).isDisjoint(with: LeadImage.keys(lead)) else { continue }
            // A paragraph that is the caption set as text (Vice's credit line at the end) goes with it.
            let body = DOM.withFragment(html) { body -> String in
                for p in DOM.select(body, "p") where DOM.norm(DOM.text(p)) == DOM.norm(words) || (DOM.text(p).count >= 20 && DOM.norm(words).contains(DOM.norm(DOM.text(p))) && isCredit(DOM.text(p))) {
                    DOM.remove(p)
                }
                return DOM.innerHTML(body)
            } ?? html
            // A caption the body still has is the body's own figure under another URL (a diagram that is also the lead).
            guard words.count < 20 || !DOM.norm(DOM.plainText(body)).contains(DOM.norm(words)) else { continue }
            let alt = DOM.attr(img, "alt").map { " alt=\"\(DOM.escapeAttr($0))\"" } ?? ""
            // The lead's own URL: the size the reader drew before (the page's src can be a 560px variant).
            let figure = ArticleSanitizer.sanitize("<figure><img src=\"\(DOM.escapeAttr(lead))\"\(alt)><figcaption>\(DOM.escapeHTML(words))</figcaption></figure>")
            return figure + body
        }
        return html
    }

    /// "… Photograph: Roger Anis/AP Photograph: Roger Anis/AP": the Guardian ships a caption once per layout and
    /// both copies' credits land in one. The repeated tail goes.
    static func dropRepeatedTail(_ s: String) -> String {
        let words = s.split(separator: " ")
        let n = words.count
        for k in stride(from: n / 2, through: 2, by: -1) where words[(n - k)...] == words[(n - 2 * k)..<(n - k)] {
            return words[..<(n - k)].joined(separator: " ")
        }
        return s
    }
}
