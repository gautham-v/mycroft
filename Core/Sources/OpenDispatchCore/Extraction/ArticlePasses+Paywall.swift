import Foundation
import SwiftSoup

/// Passes and page checks for soft barriers and teasers: text a site serves but hides (Kiosq), and the line at which a
/// subscriber-only preview says it stops (Springer Nature, Le Monde).
extension ArticlePasses {
    // MARK: unhideSoftBarrierText

    private static let minHiddenProse = 40
    private static let minVisibleProse = 80

    /// Kiosq (Tom's Hardware, PC Gamer's sister sites) marks every paragraph after the first one or two `aria-hidden="true"`
    /// and fades them out client-side; the whole story is in the HTML. Readability skips aria-hidden nodes, so the reader
    /// got two paragraphs and a paywall flag. A paragraph of prose marked aria-hidden beside visible paragraphs of prose
    /// is part of the story (aria-hidden icon glyphs and tooltips are never paragraphs in a run of body text).
    static func unhideSoftBarrierText(_ root: Element) {
        for p in DOM.select(root, "p[aria-hidden=true]") {
            guard DOM.textLen(DOM.rawText(p)) >= minHiddenProse, let parent = p.parent(),
                  DOM.children(parent).contains(where: {
                      DOM.tag($0) == "p" && DOM.attr($0, "aria-hidden") != "true" && DOM.textLen(DOM.rawText($0)) >= minVisibleProse
                  }) else { continue }
            DOM.removeAttr(p, "aria-hidden")
        }
    }

    // MARK: removeVideoCarousel

    /// JW Player's "Latest Videos From <site>" carousel (an empty player host, its header and a signposting link) that
    /// sits between paragraphs on Future plc sites.
    static func removeVideoCarousel(_ root: Element) {
        for header in DOM.select(root, "[data-jwp-carousel-header]") {
            guard DOM.isConnected(header), let carousel = header.parent(), carousel !== root,
                  DOM.first(carousel, "[data-jwp-carousel-container]") != nil else { continue }
            DOM.remove(carousel)
        }
    }

    // MARK: paywallMarker

    private static let gap = "(?:\\s|&nbsp;|\\u00A0)+"
    /// The page itself saying the article is cut off here: Springer Nature's "This is a preview of subscription content",
    /// Le Monde's "You have 86.43% of this article left to read. The rest is for subscribers only." (and its French
    /// "Il vous reste 86,43 % de cet article à lire"), "The rest of this story is for subscribers".
    static let paywallMarker = P(
        "this\(gap)is\(gap)a\(gap)preview\(gap)of\(gap)subscription\(gap)content"
        + "|you\(gap)have\(gap)\\d+(?:[.,]\\d+)?(?:\\s|&nbsp;|\\u00A0)*%\(gap)of\(gap)this\(gap)(?:article|story)\(gap)left\(gap)to\(gap)read"
        + "|il\(gap)vous\(gap)reste\(gap)\\d+(?:[.,]\\d+)?(?:\\s|&nbsp;|\\u00A0)*%\(gap)de\(gap)cet\(gap)article"
        + "|the\(gap)rest\(gap)(?:of\(gap)(?:this|the)\(gap)(?:article|story)\(gap))?is\(gap)(?:only\(gap))?for\(gap)(?:our\(gap))?subscribers",
        caseInsensitive: true)

    private static let minTextBeforeMarker = 120

    // MARK: cutAtPaywallMarker

    /// The marker's line and everything after it go: what follows a preview is the site's pricing block, "similar content"
    /// cards, author lists and the like (Nature), and the line itself is what the reader's paywall banner says. Nothing is
    /// cut unless a real stretch of text stays above it.
    static func cutAtPaywallMarker(_ root: Element) {
        guard paywallMarker.test(DOM.rawText(root)) else { return }
        // The deepest element whose own text holds the marker, in document order.
        guard var marker = DOM.select(root, "*").first(where: { el in
            paywallMarker.test(DOM.rawText(el)) && !DOM.children(el).contains(where: { paywallMarker.test(DOM.rawText($0)) })
        }) else { return }
        // <p><strong>marker</strong></p>: the line is the paragraph.
        while let parent = marker.parent(), parent !== root, DOM.squash(DOM.rawText(parent)) == DOM.squash(DOM.rawText(marker)) { marker = parent }
        var gone: [Node] = [marker]
        var node: Node = marker
        while node !== root, let parent = node.parent() {
            gone += parent.getChildNodes().drop(while: { $0 !== node }).dropFirst()
            node = parent
        }
        let removed = gone.reduce(0) { $0 + DOM.textLen(DOM.rawText($1)) }
        guard DOM.textLen(DOM.rawText(root)) - removed >= minTextBeforeMarker else { return }
        gone.forEach { DOM.remove($0) }
    }
}

extension PaywallDetection {
    private typealias DOM = ExtractionDOM

    private static let wallWording = DOM.Pattern(
        "subscription required|subscribers only|(?:available|reserved|restricted) (?:to|for) [^.]{0,40}subscribers", caseInsensitive: true)
    private static let wallSentence = DOM.Pattern(
        "[^.!?]*(?:subscription required|subscribers only|(?:available|reserved|restricted) (?:to|for) [^.]{0,40}subscribers)[^.!?]*[.!?]?",
        caseInsensitive: true)
    private static let maxWallSentence = 300

    /// An error response (401, 402, 403) whose page is the site's own wall rather than a bot check: LWN answers a
    /// subscriber-only article with 403 and "The page you have tried to view (…) is currently available to LWN subscribers
    /// only." The sentence stands for the article, paywalled, so the reader can offer the sign-in instead of "status(403)".
    static func wallResponse(_ html: String) -> ExtractResult? {
        guard wallWording.test(html), let doc = DOM.parseDocument(html) else { return nil }
        for junk in DOM.select(doc, "script, style, noscript, form, nav, header, footer") { DOM.remove(junk) }
        let scope = DOM.first(doc, "main, article, [role=main]") ?? DOM.first(doc, "body") ?? doc
        guard let sentence = wallSentence.firstMatch(DOM.text(scope))?[0].map(DOM.squash), !sentence.isEmpty else { return nil }
        let line = sentence.count > maxWallSentence ? "The site shows this page to subscribers only." : sentence
        return ExtractResult(contentHtml: "<p>\(DOM.escapeHTML(line))</p>", leadImage: nil, paywalled: true)
    }
}
