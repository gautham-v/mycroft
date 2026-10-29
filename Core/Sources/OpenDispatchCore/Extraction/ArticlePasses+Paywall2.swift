import Foundation
import SwiftSoup

/// What a walled page puts around its teaser, and walls the first rounds missed: the offer box (Der Spiegel's SPIEGEL+
/// box, Springer Nature's access options), print-only lines, the access label and language switch under a title (Le
/// Monde), the byline and date lines in the title's header, test-attribute newsletter and byline cards (the Washington
/// Post), subscription pitches in the text, TownNews' ciphered bodies (St. Louis Post-Dispatch), and a barrier page
/// served in place of the article (the FT). `removeAccessChrome` runs on the page before Readability.
extension ArticlePasses {
    static func removeAccessChrome(_ root: Element) {
        removePrintOnly(root)
        removeOfferBoxes(root)
        removeTownNewsWall(root)
        removeAccessLabels(root)
        removeLanguageSwitches(root)
        removeTitleHeaderMeta(root)
        removeTestAttributeCards(root)
        removeSubscriptionPitches(root)
    }

    // MARK: Print-only blocks

    /// Blocks drawn only on paper: the Washington Post's logo and slogan (`dn show-for-print`), Der Spiegel's "Dieser
    /// Ausdruck wurde am … erstellt" licence line (Tailwind's `hidden print:block`). Readability can't see CSS.
    private static let printOnly: Set<String> = ["show-for-print", "print-only", "only-print", "visible-print", "visible-print-block", "printonly"]
    private static let printShown: Set<String> = ["print:block", "print:flex", "print:inline", "print:inline-block", "d-print-block", "d-print-flex", "d-print-inline"]
    private static let screenHidden: Set<String> = ["hidden", "dn", "d-none"]

    static func removePrintOnly(_ root: Element) {
        for el in DOM.select(root, "[class]") where DOM.isConnected(el) && !DOM.isTag(el, ["html", "body", "main", "article"]) {
            let tokens = Set(DOM.classTokens(el))
            guard !tokens.isDisjoint(with: printOnly) || (!tokens.isDisjoint(with: printShown) && !tokens.isDisjoint(with: screenHidden)) else { continue }
            DOM.remove(el)
        }
    }

    // MARK: Offer boxes

    /// A box the page names a paywall or an entitlement in a data attribute is the offer, not the story: Der Spiegel's
    /// `data-area="paywall"` ("Diesen Artikel weiterlesen mit SPIEGEL+", prices, benefits), Springer Nature's
    /// `data-test="entitlement-box-main"` (institution access) and its `c-journal-buybox` (subscription prices).
    /// One holding a paragraph of prose is a wrapper around the story and stays.
    private static let offerName = P("(?<!no-)(?<!no_)paywall|entitlement", caseInsensitive: true)
    private static let buyBox = P("buy-?box", caseInsensitive: true)
    private static let accessWords = P("\\bsubscri|\\baccess\\b|rent or buy", caseInsensitive: true)
    private static let offerAttrs = ["data-area", "data-test", "data-testid", "data-qa", "data-component", "data-target-id"]
    private static let accessHeading = P("^(?:access|purchase|buying|subscription) options$", caseInsensitive: true)
    private static let offerProse = 200

    static func removeOfferBoxes(_ root: Element) {
        let query = (offerAttrs.map { "[\($0)]" } + ["[class*=buybox]", "[id*=buybox]", "[class*=buy-box]"]).joined(separator: ", ")
        for el in DOM.select(root, query) where DOM.isConnected(el) && !DOM.isTag(el, ["html", "body", "main", "article"]) {
            let named = offerAttrs.contains(where: { DOM.attr(el, $0).map(offerName.test) == true })
            // A shop's buy box (Macworld's "At a glance" picks with "View Deal") is the story's; one selling access isn't.
            let sellsAccess = (buyBox.test(DOM.attr(el, "class") ?? "") || buyBox.test(DOM.attr(el, "id") ?? "")) && accessWords.test(DOM.text(el))
            guard named || sellsAccess,
                  !DOM.select(el, "p").contains(where: { DOM.textLen(DOM.text($0)) >= offerProse }) else { continue }
            // Its heading ("Access options") goes with it.
            if let prev = try? el.previousElementSibling(), DOM.isTag(prev, DOM.headingTags), accessHeading.test(DOM.text(prev)) { DOM.remove(prev) }
            DOM.remove(el)
        }
    }

    // MARK: TownNews (site platform)

    /// TownNews BLOX (Lee Enterprises' papers and hundreds of others) ships a walled story with `data-content-encrypted`
    /// on the body and the text ciphered in hidden `.encrypted-content` blocks; what a reader without a subscription gets
    /// is the `.subscriber-preview` paragraph and the story's pictures. That is a line or two, too little for Readability,
    /// which then took a video caption or the related-story cards, or nothing. The headline, the preview and the
    /// pictures are the article (with neither, Readability finds nothing and the description is the teaser). On every
    /// TownNews page the inline related-story cards ("People are also reading…", headline links) and the "Related to this
    /// story" row are promos.
    static func removeTownNewsWall(_ root: Element) {
        let promos = "#inline-article-recommend, .tnt-inline-relcontent.tnt-inline-article, .tnt-inline-relcontent.tnt-inline-link, #article-related-bottom-container"
        if DOM.first(root, "[class*=tnt-]") != nil {
            for el in DOM.select(root, promos) where DOM.isConnected(el) { DOM.remove(el) }
        }
        guard let story = DOM.first(root, "[data-content-encrypted=true]"), let page = DOM.first(root, "body") else { return }
        var parts: [String] = []
        for el in DOM.select(story, ".subscriber-preview.lee-article-text, .tnt-inline-image") {
            if DOM.matches(el, ".subscriber-preview") {
                parts.append(DOM.innerHTML(el))
            } else if let figure = townNewsFigure(el) {
                parts.append(figure)
            }
        }
        let title = ArticleExtraction.headline(root).map(DOM.outerHTML) ?? ""
        _ = try? page.html("<article>" + title + "<div>" + parts.joined() + "</div></article>")
    }

    /// A TownNews picture as a plain figure: its lazy `<img>` holds a placeholder (the picture is in the schema.org
    /// `contentUrl`), and its caption is a paragraph Readability would score above the preview.
    private static func townNewsFigure(_ asset: Element) -> String? {
        guard let src = DOM.first(asset, "meta[itemprop=contentUrl], meta[itemprop=url]").flatMap({ DOM.attr($0, "content") }) else { return nil }
        let alt = DOM.first(asset, "img").flatMap { DOM.attr($0, "alt") } ?? ""
        let caption = [DOM.first(asset, ".caption-text"), DOM.first(asset, ".credit")].compactMap { $0.map(DOM.text) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "<figure><img src=\"\(DOM.escapeAttr(src))\" alt=\"\(DOM.escapeAttr(alt))\">"
            + (caption.isEmpty ? "" : "<figcaption>\(DOM.escapeHTML(caption))</figcaption>") + "</figure>"
    }

    // MARK: Access labels and language switches

    /// The badge under a title saying who may read on (Le Monde's "Subscribers only" with its lock icon). Only a line
    /// that is the label and nothing else.
    private static let accessLabel = P(
        "^(?:for )?subscribers?[- ]only$|^subscriber exclusive$|^exclusive (?:for|to) subscribers$|^réservé aux abonnés$|^nur für abonnenten$|^solo para suscriptores$",
        caseInsensitive: true)

    static func removeAccessLabels(_ root: Element) {
        for el in DOM.select(root, "p, span, div, li, a, strong") where DOM.isConnected(el) {
            let t = DOM.text(el)
            guard t.count <= 40, accessLabel.test(t), DOM.select(el, "img, video, iframe, picture").isEmpty else { continue }
            DOM.remove(lineBlock(el, root: root))
        }
    }

    /// A link to the article in another language (`hreflang`; Le Monde's "Lire en français") is the page's switch. Only
    /// a link standing alone: one inside a sentence is part of it.
    static func removeLanguageSwitches(_ root: Element) {
        for a in DOM.select(root, "a[hreflang]") where DOM.isConnected(a) {
            let t = DOM.text(a)
            guard t.count <= 40 else { continue }
            if let line = DOM.closest(a, "p, li"), DOM.text(line) != t { continue }
            DOM.remove(a)
        }
    }

    // MARK: The title's header

    private static let headerByline = P("^[Bb]y\\s+\\p{Lu}")
    private static let headerDate = P("^(?:published|updated|posted|modified|first published)\\b", caseInsensitive: true)
    private static let headerLine = 120
    private static let inlineTags: Set<String> = ["span", "time", "a", "em", "i", "strong", "b", "small"]

    /// The `<header>` holding the headline also holds the byline ("By Claire Gatinois and Benjamin Quénelle (Istanbul…)"),
    /// the date ("Published today at 5:31 pm (Paris)", Der Spiegel's bare `<time>`) and the read time. The reader draws
    /// the title and author itself, and a site whose header sits inside its article column has them kept. Lines after the
    /// headline that are a byline, a labelled date or only a `<time>` go; the dek and pictures stay.
    static func removeTitleHeaderMeta(_ root: Element) {
        guard let h1 = ArticleExtraction.headline(root), let header = DOM.closest(h1, "header") else { return }
        let order = DOM.documentOrder(header)
        let start = order[ObjectIdentifier(h1)] ?? 0
        for el in DOM.select(header, "p, span, div, section, time, li") where DOM.isConnected(el) {
            guard (order[ObjectIdentifier(el)] ?? 0) > start, !DOM.contains(el, h1) else { continue }
            let t = DOM.text(el)
            guard !t.isEmpty, t.count <= headerLine, DOM.select(el, "img, video, iframe, picture, figure").isEmpty else { continue }
            let onlyTime = DOM.first(el, "time").map { DOM.text($0) == t } ?? (DOM.tag(el) == "time")
            let byline = headerByline.test(t) && !t.hasSuffix(".") && DOM.select(el, "a[href]").count <= 3
            guard onlyTime || byline || headerDate.test(t) else { continue }
            // A whole line only: the date of "Oct 29, 2026 · 1 minute read" is left to the date-line rule, which takes both.
            let line = lineBlock(el, root: header)
            if DOM.isTag(line, inlineTags), let parent = line.parent(), DOM.text(parent) != t { continue }
            DOM.remove(line)
        }
    }

    // MARK: Cards named by test attributes

    /// The Washington Post's byline card (`data-testid="byline-container"`: the columnist's 196px portrait, "Column by"
    /// and the column's blurb) and its newsletter sign-up (`data-qa="newsletter"`: a stock illustration and a button),
    /// named in test attributes rather than classes. Short boxes only.
    private static let cardName = P("^(?:[a-z]*-)?(?:byline-container|article-byline|author-byline|newsletter|sc-newsletter-signup|newsletter-signup)$", caseInsensitive: true)
    private static let maxCardText = 400

    static func removeTestAttributeCards(_ root: Element) {
        for el in DOM.select(root, "[data-qa], [data-testid]") where DOM.isConnected(el) && !DOM.isTag(el, ["html", "body", "main", "article"]) {
            guard [DOM.attr(el, "data-qa"), DOM.attr(el, "data-testid")].compactMap({ $0 }).contains(where: cardName.test),
                  DOM.textLen(DOM.text(el)) <= maxCardText, DOM.first(el, "h1") == nil else { continue }
            DOM.remove(el)
        }
    }

    // MARK: Subscription pitches

    /// A paragraph in the text asking for a subscription (Der Spiegel's "To enjoy the rest of this story, please consider
    /// signing up for a subscription…", the Japan Times' "By subscribing, you can help us get the story right.").
    private static let pitch = P(
        "to enjoy the rest of this story,? please consider|please consider signing up for a subscription|by subscribing,? you can help us get the story right",
        caseInsensitive: true)

    static func removeSubscriptionPitches(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.count <= 500, pitch.test(t) else { continue }
            DOM.remove(p)
        }
    }

    // MARK: Barrier pages

    private static let barrierTitle = P("^(?:subscribe|sign in|log in|register) to (?:read|continue|unlock)\\b", caseInsensitive: true)

    /// A page served in place of the article that only sells access: the FT answers a walled story with a page titled
    /// "Subscribe to read" (its prices and plans, or the Lex column's pitch), no article text at all. Its own
    /// description is the teaser (`walledTeaser`).
    static func isBarrierPage(_ document: Element) -> Bool {
        barrierTitle.test(DOM.text(DOM.first(document, "title")))
    }
}

extension PaywallDetection {
    private typealias DOM = ExtractionDOM

    /// Google's paywall markup as microdata (`<meta itemprop="isAccessibleForFree" content="false">`, TownNews) and an
    /// article body marked as ciphered (`data-content-encrypted="true"`).
    private static let accessMarks = DOM.Pattern(
        "<meta[^>]+itemprop=[\"']isAccessibleForFree[\"'][^>]+content=[\"']false[\"']|<meta[^>]+content=[\"']false[\"'][^>]+itemprop=[\"']isAccessibleForFree[\"']|\\bdata-content-encrypted=[\"']true[\"']",
        caseInsensitive: true)

    static func marksAccess(_ pageHTML: String) -> Bool { accessMarks.test(pageHTML) }

    /// A paywall phrase counts only where a reader could see it: a template the page keeps hidden (`hidden`, `display:
    /// none`) is on every page, free ones too (New York's sites ship "Already a subscriber?" in a hidden box on every
    /// story and add their paywall markup only when the meter runs out).
    static func showsPhrase(_ body: String, _ phrase: ExtractionDOM.Pattern) -> Bool {
        guard let doc = DOM.parseDocument(body) else { return true }
        for el in DOM.select(doc, "[hidden], .hidden, [style*=\"display:none\"], [style*=\"display: none\"], template") where DOM.isConnected(el) {
            DOM.remove(el)
        }
        return phrase.test(DOM.text(DOM.first(doc, "body") ?? doc))
    }
}
