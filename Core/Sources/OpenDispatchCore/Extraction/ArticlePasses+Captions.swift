import Foundation
import SwiftSoup

/// Captions and credits: the words under a picture belong in a <figcaption> (small and muted in the reader), not in
/// a body paragraph that reads as the next sentence of the story.
extension ArticlePasses {
    // MARK: captionFigures

    /// A class or id that names a caption or a credit (`wp-caption-text`, `media-credit`, `imageCaption-oOSXz`,
    /// `duet--media--caption`, `caption__credit`, `gallery-image-credit`).
    private static let captionName = P("caption|credit|cptn", caseInsensitive: true)
    /// An affiliate disclosure set in small type right after a picture (MacRumors), which reads as the picture's caption.
    private static let disclosure = P("\\baffiliate (?:partner|links?)\\b|\\bwe may (?:earn|receive) (?:a |an )?(?:small |affiliate )?(?:commission|payment)\\b", caseInsensitive: true)
    private static let maxDisclosure = 300
    private static let captionTags: Set<String> = ["div", "p", "span", "small", "cite", "figcaption", "footer", "section", "aside", "em", "i", "a"]
    private static let separating: Set<String> = ["p", "div", "span", "small", "cite", "figcaption", "footer", "section", "aside", "li", "time"]
    private static let skipInCaption: Set<String> = ["script", "style", "button", "noscript", "svg"]
    private static let hiddenStyle = P("opacity\\s*:\\s*0(?:[;\\s]|$)|display\\s*:\\s*none|visibility\\s*:\\s*hidden|(?:^|;)\\s*height\\s*:\\s*0(?:px)?\\s*(?:;|$)", caseInsensitive: true)
    private static let toggleLabel = P("^(?:hide|show|toggle|expand|collapse) caption$", caseInsensitive: true)
    private static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "”", "’", "'", "\"", "%"]
    private static let noSpaceAfter: Set<Character> = ["(", "[", "“", "‘", "$", "£", "€", "#", "@"]
    private static let noWords = P("^[.…\\s]*$")
    private static let maxCaption = 700
    private static let maxCaptionClimb = 6

    private static func isCaptionish(_ el: Element) -> Bool {
        if DOM.isTag(el, ["figcaption"]) { return true }
        guard DOM.isTag(el, captionTags) else { return false }
        return DOM.classTokens(el).contains(where: { captionName.test($0) }) || captionName.test(DOM.attr(el, "id") ?? "")
    }

    /// The element's words with a space where two elements meet ("…California." + "Katie Flores/WWD/Getty"), a
    /// credit repeated in a second element once, and show/hide controls left out.
    static func captionText(_ el: Element) -> String {
        var seen: Set<String> = []
        func flat(_ el: Element) -> String {
            var out = ""
            var prevBlock = false
            for node in el.getChildNodes() {
                var piece = ""
                var block = false
                if let t = node as? TextNode {
                    piece = t.getWholeText()
                } else if let c = node as? Element {
                    if DOM.isTag(c, skipInCaption) { continue }
                    if DOM.tag(c) == "br" { piece = " " } else {
                        block = DOM.isTag(c, separating)
                        let s = DOM.text(c)
                        if toggleLabel.test(s) { continue }
                        if block, DOM.children(c).isEmpty, !s.isEmpty {
                            if seen.contains(s) { continue }
                            seen.insert(s)
                        }
                        piece = flat(c)
                    }
                }
                if (block || prevBlock), let last = out.last, let first = piece.first, !last.isWhitespace, !first.isWhitespace,
                   !noSpaceBefore.contains(first), !noSpaceAfter.contains(last) {
                    out += " "
                }
                out += piece
                if !piece.isEmpty { prevBlock = block }
            }
            return out
        }
        return DOM.squash(flat(el))
    }

    /// All of `el`'s words are inside caption-named elements (or `el` is one): a wrapper that is only a caption.
    private static func onlyCaption(_ el: Element) -> Bool {
        if isCaptionish(el) { return true }
        guard !el.getChildNodes().isEmpty else { return false }
        for node in el.getChildNodes() {
            if let t = node as? TextNode {
                if !DOM.squash(t.getWholeText()).isEmpty { return false }
            } else if let c = node as? Element, !DOM.text(c).isEmpty, !onlyCaption(c) {
                return false
            }
        }
        return true
    }

    /// The images a block draws, a lazy-loading <noscript> copy and a responsive twin (the same picture twice, one
    /// shown per screen width: Eater, Reason) counted once.
    private static func distinctImages(_ el: Element) -> [Element] {
        var seen: Set<String> = []
        let imgs = DOM.isTag(el, ["img"]) ? [el] : DOM.select(el, "img")
        return imgs.filter { img in
            guard DOM.closest(img, "noscript") == nil else { return false }
            let key = (DOM.attr(img, "src") ?? "").split(separator: "?").first.map(String.init) ?? ""
            return seen.insert(key + (DOM.attr(img, "alt") ?? "")).inserted
        }
    }

    private static let maxPictures = 4

    /// A block that is a picture, or a few side by side (Daily Mail's left and right photos), and no words: a
    /// lazy-image wrapper, a link around a photo.
    private static func isPictureBlock(_ el: Element) -> Bool {
        if DOM.isTag(el, ["picture"]) { return true }
        guard DOM.text(el).isEmpty else { return false }
        let imgs = distinctImages(el)
        return (1...maxPictures).contains(imgs.count) && !imgs.contains(where: isTinyImg)
            && DOM.first(el, "video, iframe, audio, svg, figcaption, blockquote, table") == nil
    }

    /// The block's pictures (each <img>, or the <picture> around it) as HTML.
    private static func picturesHTML(_ block: Element) -> String {
        if DOM.isTag(block, ["picture"]) { return DOM.outerHTML(block) }
        return distinctImages(block).map { img in
            DOM.outerHTML(DOM.closest(img, "picture").flatMap { DOM.contains(block, $0) ? $0 : nil } ?? img)
        }.joined()
    }

    /// Captions a page draws beside its pictures without a <figcaption>, and ones its CSS puts under them. Each
    /// becomes a <figure> with a real <figcaption> (small, muted):
    ///  - WordPress: `div.wp-caption` of an <img> and `p.wp-caption-text` (Krebs, Mother Jones, The Tab, Daily Mail);
    ///  - a caption, or a credit, in a sibling block after the picture's wrapper (Fox: `div.info > div.caption`; Eater:
    ///    `div.duet--media--caption > cite`; Engadget: `span.gallery-image-credit`; CNN: a figcaption in a metadata
    ///    block beside the image's container);
    ///  - a caption after a <figure> that holds only the picture (CBC: `p.imageCaption`);
    ///  - a caption block inside a <figure> that has no <figcaption> (Condé Nast's `div.caption > span.caption__credit`:
    ///    Wired, Pitchfork).
    /// A caption and a credit in separate elements read as one caption, with a space between. Hidden alt-text
    /// <figcaption>s (Foreign Policy's `height:0;opacity:0`) and empty ones (Aeon) go first.
    static func captionFigures(_ root: Element) {
        for cap in DOM.select(root, "figcaption") where DOM.isConnected(cap) {
            if DOM.text(cap).isEmpty && DOM.first(cap, contentMedia) == nil || hiddenStyle.test(DOM.attr(cap, "style") ?? "") { DOM.remove(cap) }
        }
        var made = Set<ObjectIdentifier>()
        for anchor in DOM.select(root, "[class], [id], figcaption") where DOM.isConnected(anchor) {
            guard isCaptionish(anchor), anchor !== root, DOM.first(anchor, contentMedia) == nil else { continue }
            let words = captionText(anchor)
            guard !words.isEmpty, words.count <= maxCaption, !noWords.test(words) else { continue }

            // Inside a figure: a figure with a caption already is done; one without gets this block as its caption.
            if let fig = DOM.closest(anchor, "figure") {
                guard DOM.first(fig, "figcaption") == nil, fig !== anchor, DOM.first(fig, "img, picture") != nil else { continue }
                var top = anchor
                while let p = top.parent(), p !== fig, onlyCaption(p), DOM.first(p, contentMedia) == nil { top = p }
                let text = captionText(top)
                DOM.remove(top)
                _ = try? fig.append("<figcaption>\(DOM.escapeHTML(text))</figcaption>")
                continue
            }

            // Beside a picture: climb through wrappers that hold nothing but the caption until the block before the
            // wrapper is the picture.
            var top = anchor
            var found: [Element] = []
            for _ in 0..<maxCaptionClimb {
                if let prev = previousBlock(top) {
                    if made.contains(ObjectIdentifier(prev)), let cap = DOM.first(prev, "figcaption") {
                        // The credit after a caption already turned into one: the same caption.
                        let more = captionText(top)
                        DOM.remove(top)
                        _ = try? cap.append(" " + DOM.escapeHTML(more))
                        break
                    }
                    if DOM.isTag(prev, ["figure"]), DOM.first(prev, "figcaption") == nil, DOM.select(prev, "img").count == 1 {
                        let text = captionText(top)
                        DOM.remove(top)
                        _ = try? prev.append("<figcaption>\(DOM.escapeHTML(text))</figcaption>")
                        break
                    }
                    if isPictureBlock(prev), DOM.closest(prev, "figure") == nil {
                        // Photos side by side (Daily Mail's left and right) share the caption below them.
                        found = [prev]
                        while found.count < maxPictures, let before = previousBlock(found[0]), isPictureBlock(before) { found.insert(before, at: 0) }
                        break
                    }
                }
                guard let p = top.parent(), p !== root, !(p is Document), !DOM.isTag(p, ["body", "html", "article", "main"]),
                      onlyCaption(p), DOM.first(p, contentMedia) == nil else { break }
                top = p
            }
            guard let block = found.first else { continue }
            let text = captionText(top)
            DOM.remove(top)
            _ = try? block.before("<figure>\(found.map(picturesHTML).joined())<figcaption>\(DOM.escapeHTML(text))</figcaption></figure>")
            if let fig = try? block.previousElementSibling() { made.insert(ObjectIdentifier(fig)) }
            found.forEach { DOM.remove($0) }
        }
    }

    /// The block before `el`, past empty spacers (`<div class="clear">`, `<br>`).
    private static func previousBlock(_ el: Element) -> Element? {
        var prev = try? el.previousElementSibling()
        while let p = prev, DOM.text(p).isEmpty, !DOM.matches(p, contentMedia), DOM.first(p, contentMedia) == nil {
            prev = try? p.previousElementSibling()
        }
        return prev
    }

    // MARK: tidyCaptions

    /// A caption's parts meet without a space once the page's styling is gone (DW's `<small>Image: AFP</small>` right
    /// after the caption, Cleveland.com's nested credit span), and a figure whose picture was dropped as page furniture
    /// is left with only the words that went with it (Apple Newsroom's share-sheet images). An affiliate disclosure
    /// glued under a picture (MacRumors' `<em><small>Note: MacRumors is an affiliate partner…`) is no caption: it goes.
    static func tidyCaptions(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            if DOM.first(fig, contentMedia) == nil, !DOM.children(fig).isEmpty, DOM.children(fig).allSatisfy({ DOM.isTag($0, ["figcaption"]) }) {
                DOM.remove(fig)
            }
        }
        for el in DOM.select(root, "em, i, small, span") where DOM.isConnected(el) {
            let words = DOM.text(el)
            guard !words.isEmpty, words.count <= maxDisclosure, disclosure.test(words), DOM.first(el, contentMedia) == nil,
                  let box = el.parent(), box !== root, DOM.first(box, "img, picture") != nil else { continue }
            DOM.remove(el)
        }
        for caption in DOM.select(root, "figcaption") {
            for el in DOM.select(caption, "*") where DOM.isTag(el, separating) && !DOM.text(el).isEmpty {
                guard let prev = el.previousSibling(), let last = DOM.rawText(prev).last, let first = DOM.rawText(el).first,
                      !last.isWhitespace, !first.isWhitespace, !noSpaceBefore.contains(first), !noSpaceAfter.contains(last) else { continue }
                _ = try? el.before(" ")
            }
        }
    }
}
