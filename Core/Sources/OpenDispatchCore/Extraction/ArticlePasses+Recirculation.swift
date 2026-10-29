import Foundation
import SwiftSoup

/// Site chrome inside or after the article that Readability keeps: recirculation modules ("Popular Reads", "Read next",
/// "Recommended Stories"), labelled and shouting promo links ("Read: <story>", "NEXT: <story>", Fox's all-caps lines),
/// newsletter pitches, sponsor and affiliate blocks, press-release end matter, and a stream site's following posts.
extension ArticlePasses {
    // MARK: Before Readability (class names and page structure are intact)

    /// Modules a site marks with its own markup, found while the classes are still there. Keyed by host suffix.
    private static let siteModules: [(host: String, selector: String)] = [
        // BleepingComputer's sponsored vendor-report callout and its related-article list after the story.
        ("bleepingcomputer.com", ".article-callout, .cz-related-article-wrapp"),
        // MLB.com's shop ad ("Get Brewers World Series champions gear!") is a story part of its own.
        ("mlb.com", ".story-part.dynamicinclude"),
        // The Cool Down's newsletter graphic and its "Cool Picks" sponsored grid.
        ("thecooldown.com", "[class*=wp-block-tcd-cool-]"),
    ]

    /// A class naming a list of links to other stories (CBC's `similarLinksContainer`, Business Insider's `read-next`).
    private static let recircClass = P("^(?:similar|related|recommended|more-on|read-next|recirc)", caseInsensitive: true)
    static let maxRecircModuleText = 1200

    static func removeRecirculation(_ root: Element, pageURL: String) {
        let host = DOM.hostname(pageURL)?.lowercased() ?? ""
        for (suffix, selector) in siteModules where host == suffix || host.hasSuffix("." + suffix) {
            for el in DOM.select(root, selector) where DOM.isConnected(el) { DOM.remove(el) }
        }
        // A live-blog style stream (The New Republic's /post/ pages) puts the following posts in the same page, one
        // `article.post` after another, and Readability takes them all: the page's own post is the first.
        if host.hasSuffix("newrepublic.com"), pageURL.contains("/post/") {
            let posts = DOM.select(root, "article.post")
            if posts.count > 1 { for post in posts.dropFirst() where DOM.isConnected(post) { DOM.remove(post) } }
        }
        // A short, link-dense box with a recirculation class: only links to other stories, no prose.
        for el in DOM.select(root, "ul, ol, div, section, aside") where DOM.isConnected(el) {
            guard DOM.classTokens(el).contains(where: { recircClass.test($0) }) else { continue }
            let text = DOM.text(el)
            if text.count <= maxRecircModuleText, isLinkDense(el) || isTeaserRun(el) { DOM.remove(el) }
        }
    }

    // MARK: After Readability (the article's own markup)

    /// Everything below works on the cleaned article, called from `cleanArticle` once author cards and generic
    /// boilerplate are gone.
    static func removeRecirculationText(_ root: Element, base: String?) {
        removeEndMatter(root)
        removeSubscribeTail(root)
        removeRecirculationModules(root)
        removePromoLines(root)
        removeLabelledLinks(root)
        removeShoutingLinks(root)
        removeAffiliateLists(root)
        removeNewsletterPitches(root)
        removeLoneLinkLists(root, base: base)
        removeTrailingTagLinks(root)
        // A rule left at the very end, between the story and what was cut.
        for hr in DOM.select(root, "hr") where DOM.isConnected(hr) && nextContent(hr, root: root) == nil { DOM.remove(hr) }
    }

    // MARK: Teasers

    private static func rank(_ el: Element) -> Int? {
        let t = DOM.tag(el)
        return DOM.headingTags.contains(t) ? Int(t.dropFirst()) : nil
    }

    /// Anchor text is most of the element's text.
    static func isLinkDense(_ el: Element) -> Bool {
        let total = DOM.text(el).count
        guard total > 0 else { return false }
        if DOM.tag(el) == "a" { return true }
        let linked = DOM.select(el, "a[href]").reduce(0) { $0 + DOM.text($1).count }
        return Double(linked) >= 0.7 * Double(total)
    }

    private static let ellipsis = P("(?:\\.\\.\\.|…|\\[…\\]|\\[\\.\\.\\.\\])$")

    /// A teaser card's parts: images, card titles (a heading deeper than the module's own), link-only lists and
    /// paragraphs, excerpts cut with an ellipsis, and boxes made of nothing else. Prose is never a teaser.
    static func isTeaser(_ el: Element, below level: Int) -> Bool {
        let tag = DOM.tag(el)
        if let r = rank(el) { return r > level }
        if ["hr", "br", "script", "style", "img", "picture", "svg", "source", "time"].contains(tag) { return true }
        let text = DOM.text(el)
        if text.isEmpty { return true }
        switch tag {
        case "a": return text.count <= 400
        case "p": return isLinkDense(el) || ellipsis.test(text)
        case "ul", "ol": return DOM.children(el).allSatisfy { isLinkDense($0) || isTeaser($0, below: level) }
        case "li", "figcaption", "span", "small", "strong", "b", "em", "i":
            return isLinkDense(el) || (DOM.children(el).isEmpty ? false : DOM.children(el).allSatisfy { isTeaser($0, below: level) })
        default:
            if isLinkDense(el) && text.count <= 600 { return true }
            let own = el.getChildNodes().compactMap { ($0 as? TextNode).map { DOM.squash($0.getWholeText()) } }.joined()
            return own.count <= 60 && DOM.children(el).allSatisfy { isTeaser($0, below: level) }
        }
    }

    /// The element holds teasers only (a card list).
    static func isTeaserRun(_ el: Element) -> Bool {
        DOM.children(el).allSatisfy { isTeaser($0, below: 1) }
    }

    // MARK: Recirculation modules

    // The title of a box of links to other stories, wherever it sits: "Popular Reads" (ABC News), "Recommended
    // Stories" (Al Jazeera), "Popular Stories" (MacRumors), "Read next" (Business Insider), "Read more CNBC tech
    // news", "Read more" (Ghost sites' post grid), "Related topics".
    static let recircTitle = P("^(?:(?:most )?popular (?:reads?|stories|posts|articles|now)|most (?:read|viewed|shared|popular|emailed)|recommended (?:for you|stories|reads|articles|posts|reading)|read next|up next|you (?:may|might) also (?:like|enjoy|want to (?:read|see))|you may like|more (?:stories|articles|posts|news|reads|to read)(?: from [^.]{1,40})?|read more(?: [^.]{1,40})?|related (?:stories|articles|posts|coverage|content|reading|links|topics)|don['’]t miss|trending (?:now|stories|articles)|from around the web|sponsored (?:content|stories|links)|cool picks)\\s*:?$", caseInsensitive: true)

    /// A recirculation title with the teasers after it: the title and the cards go. A title left alone (the cards were
    /// already dropped, or prose follows) goes by itself, since it splits the story for nothing.
    static func removeRecirculationModules(_ root: Element) {
        for h in DOM.select(root, "h1, h2, h3, h4, h5, h6, p, div") where DOM.isConnected(h) {
            let t = DOM.text(h)
            guard !t.isEmpty, t.count <= 60, recircTitle.test(t) else { continue }
            // A bold or plain line standing for a heading, not a block with other things in it.
            if !DOM.isTag(h, DOM.headingTags), !DOM.children(h).allSatisfy({ DOM.isTag($0, ["strong", "b", "span", "a", "em"]) }) { continue }
            let head = lineBlock(h, root: root)
            let level = rank(h) ?? 2
            var run: [Element] = []
            var next = (try? head.nextElementSibling()) ?? nil
            while let sib = next, isTeaser(sib, below: level) {
                run.append(sib)
                next = (try? sib.nextElementSibling()) ?? nil
            }
            for el in run { DOM.remove(el) }
            DOM.remove(head)
        }
    }

    // MARK: Promo lines

    private static let promoLines = [
        // Fox's audio widget: "NEW You can now listen to Fox News articles!"
        P("^(?:new\\s*)?you can now listen to [^.]{1,40} articles?!?$", caseInsensitive: true),
        // Substack's empty state of its "Discussions" widget.
        P("^no posts$", caseInsensitive: true),
        // MacRumors' signup form leftovers.
        P("^leave this field empty$", caseInsensitive: true),
        P("^get weekly top [^.]{1,40} in your inbox\\.?$", caseInsensitive: true),
        // A live blog's prompt to join the chat (The Athletic): "Sound off with your thoughts in the game chat or email us".
        P("^sound off\\b.{0,200}$", caseInsensitive: true),
        // An affiliate disclosure under the story ("FTC: We use income earning auto affiliate links. More.").
        P("^ftc:.{0,160}\\baffiliate\\b.{0,60}$", caseInsensitive: true),
    ]
    /// A sponsor's message in a newsletter ("Sponsor message: ..."), up to its call to action.
    private static let sponsorMessage = P("^sponsor(?:ed)? (?:message|content|post|note)\\s*:", caseInsensitive: true)
    /// The label alone of a related-story card whose headline is gone: "Editor's Pick:", "Read about the firing:".
    private static let orphanLabel = P("^(?:editor['’]s picks?|read (?:more )?about [^:]{1,40}|read also|see also|related|more)\\s*:$", caseInsensitive: true)
    private static let footnoteStar = P("^\\*\\s*\\S")

    static func removePromoLines(_ root: Element) {
        for el in DOM.select(root, "p, li") where DOM.isConnected(el) {
            let t = DOM.text(el)
            guard !t.isEmpty, t.count <= 1200 else { continue }
            let short = t.count <= 220
            if sponsorMessage.test(t), DOM.tag(el) == "p" {
                // The sponsor's text can run on into following paragraphs of the same box.
                if let box = el.parent(), box !== root, DOM.children(box).first === el, DOM.children(box).allSatisfy({ DOM.tag($0) == "p" }),
                   DOM.text(box).count <= 1500 {
                    DOM.remove(lineBlock(box, root: root))
                } else {
                    DOM.remove(lineBlock(el, root: root))
                }
                continue
            }
            var drop = short && promoLines.contains(where: { $0.test(t) })
            if !drop, short, DOM.tag(el) == "p", orphanLabel.test(t), DOM.first(el, "a[href]") == nil { drop = true }
            // "*Buy Mac with 15% discount from Apple refurbished": the footnote of a star that isn't in the text.
            if !drop, t.count <= 100, DOM.tag(el) == "p", footnoteStar.test(t), DOM.select(el, "a[href]").count == 1, isLinkDense(el) { drop = true }
            guard drop else { continue }
            let block = lineBlock(el, root: root)
            // A list item alone in its list takes the list with it.
            if DOM.tag(block) == "li", let list = block.parent(), DOM.isTag(list, ["ul", "ol"]), DOM.children(list).count == 1 {
                DOM.remove(lineBlock(list, root: root))
            } else {
                DOM.remove(block)
            }
        }
    }

    // MARK: Labelled and shouting links

    private static let linkLabel = P("^(?:read|next|up next|read next|previous|see|related|more|also|editor['’]s picks?|recommended|don['’]t miss|plus)\\s*:\\s*", caseInsensitive: true)

    /// "Read: <story>" (The Atlantic), "NEXT: <story>" (Reason): a label and one link, nothing else. The label may sit
    /// inside the link.
    static func removeLabelledLinks(_ root: Element) {
        for p in DOM.select(root, "p, li") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.count <= 220, let label = linkLabel.firstMatch(t)?[0] else { continue }
            let links = DOM.select(p, "a[href]")
            guard links.count == 1 else { continue }
            let rest = DOM.squash(String(t.dropFirst(label.count)))
            let linkText = DOM.text(links[0])
            guard !rest.isEmpty, linkText == t || linkText == rest else { continue }
            DOM.remove(lineBlock(p, root: root))
        }
    }

    /// Fox News' related and promo links are a paragraph of one bold ALL-CAPS link ("MOM OF 2 WHO DIED RESCUING SONS…",
    /// "CLICK HERE TO DOWNLOAD THE FOX NEWS APP"). A line in capitals that is nothing but a link is a promo, not prose.
    static func removeShoutingLinks(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let t = DOM.text(p)
            let letters = t.filter { $0.isLetter }
            guard letters.count >= 8, t.split(separator: " ").count >= 2, t == t.uppercased(), t.count <= 220 else { continue }
            let links = DOM.select(p, "a[href]")
            guard links.count == 1, DOM.text(links[0]) == t else { continue }
            DOM.remove(lineBlock(p, root: root))
        }
    }

    // MARK: Affiliate lists

    private static let affiliateHost = P("^https?://(?:[\\w-]+\\.)*(?:amzn\\.to|amzn\\.com|geni\\.us|shop-links\\.co|prf\\.hn|howl\\.me|go\\.redirectingat\\.com|shareasale\\.com|linksynergy\\.com|awin1\\.com|anrdoezrs\\.net|jdoqocy\\.com|tkqlhce\\.com|kqzyfj\\.com|go\\.skimresources\\.com|click\\.linksynergy\\.com|redirect\\.viglink\\.com)/", caseInsensitive: true)
    private static let amazonTag = P("^https?://(?:www\\.)?amazon\\.[a-z.]+/[^?]*\\?[^#]*\\btag=", caseInsensitive: true)
    static let maxTailAfterAffiliate = 200

    /// 9to5's "Best iPhone accessories" at the end of a story: a list of nothing but affiliate links (with the heading
    /// above it). Only at the end, where it is a footer; a product list in the middle of a review is the review.
    static func removeAffiliateLists(_ root: Element) {
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.select(list, "li")
            guard !items.isEmpty, items.allSatisfy({ li in
                guard let a = DOM.first(li, "a[href]"), let href = DOM.attr(a, "href") else { return false }
                return affiliateHost.test(href) || amazonTag.test(href)
            }) else { continue }
            let block = lineBlock(list, root: root)
            guard tailText(after: block, root: root) <= maxTailAfterAffiliate else { continue }
            var heading = (try? block.previousElementSibling()) ?? nil
            if let h = heading, !DOM.isTag(h, DOM.headingTags), !(DOM.isTag(h, ["p", "strong", "b"]) && DOM.text(h).count <= 60 && DOM.text(h).hasSuffix(":")) { heading = nil }
            DOM.remove(block)
            if let heading { DOM.remove(heading) }
        }
    }

    /// Text after `block` in the article (what is left once it goes).
    private static func tailText(after block: Element, root: Element) -> Int {
        var total = 0
        var cur: Node? = nextOutside(block)
        while let c = cur, DOM.contains(root, c) {
            if let el = c as? Element { total += DOM.text(el).count } else if let t = c as? TextNode { total += DOM.textLen(t.getWholeText()) }
            cur = nextOutside(c)
        }
        return total
    }

    // MARK: Newsletter pitches

    private static let newsletterPitch = P("^(?:get|sign up|subscribe|join|receive)\\b.{0,80}\\bnewsletters?\\b", caseInsensitive: true)
    private static let newsletterHref = P("newsletter|subscribe|sign-?up|eepurl|list-manage", caseInsensitive: true)
    private static let newsletterTitle = P("^(?:[\\p{L}' ]{0,30})newsletter$", caseInsensitive: true)
    private static let signUpWords = P("\\bsign up\\b|\\bsubscribe\\b", caseInsensitive: true)

    /// "Get TCD's free newsletters for easy tips…" and the graphic linking to the newsletter page above it, MacRumors'
    /// "Deals Newsletter" heading with its sign-up sentence: a pitch for the site's mailing list.
    static func removeNewsletterPitches(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.count <= 360, newsletterPitch.test(t) else { continue }
            let links = DOM.select(p, "a[href]")
            guard links.contains(where: { newsletterHref.test(DOM.attr($0, "href") ?? "") || newsletterHref.test(DOM.text($0)) }) else { continue }
            // The banner image linking to the same page just above it.
            if let prev = (try? p.previousElementSibling()) ?? nil, DOM.text(prev).isEmpty, isNewsletterBanner(prev) { DOM.remove(lineBlock(prev, root: root)) }
            DOM.remove(lineBlock(p, root: root))
        }
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            guard let a = DOM.closest(img, "a[href]"), newsletterHref.test(DOM.attr(a, "href") ?? "") else { continue }
            let block = lineBlock(a, root: root)
            if DOM.text(block).isEmpty, DOM.select(block, "img").count == 1 { DOM.remove(block) }
        }
        for h in DOM.select(root, "h2, h3, h4") where DOM.isConnected(h) {
            guard DOM.text(h).count <= 40, newsletterTitle.test(DOM.text(h)) else { continue }
            guard let next = (try? h.nextElementSibling()) ?? nil, DOM.tag(next) == "p", DOM.text(next).count <= 400,
                  signUpWords.test(DOM.text(next)), DOM.first(next, "a[href]") != nil else { continue }
            DOM.remove(next)
            DOM.remove(h)
        }
    }

    private static func isNewsletterBanner(_ el: Element) -> Bool {
        DOM.select(el, "img").count == 1 && DOM.select(el, "a[href]").contains { newsletterHref.test(DOM.attr($0, "href") ?? "") }
    }

    // MARK: Lone link lists

    private static let wwwPrefix = P("^www\\.")
    static let maxLoneListItems = 4

    /// MLB.com's "read also" blocks and CBC's related-story lists sit between paragraphs as a bulleted list of one to
    /// four links to other stories on the same site: each item is a link and nothing else, after a sentence that does
    /// not introduce a list ("Sources:") and not under a heading.
    static func removeLoneLinkLists(_ root: Element, base: String?) {
        guard let base, let host = DOM.hostname(base).map({ wwwPrefix.replacing($0.lowercased(), with: "") }) else { return }
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.children(list)
            guard (1...maxLoneListItems).contains(items.count), items.allSatisfy({ DOM.tag($0) == "li" }) else { continue }
            let internalLinks = items.allSatisfy { li in
                guard let a = DOM.first(li, "a[href]"), DOM.text(a) == DOM.text(li), DOM.text(li).count >= 20,
                      let h = DOM.attr(a, "href").flatMap({ DOM.hostname($0) }) else { return false }
                let linkHost = wwwPrefix.replacing(h.lowercased(), with: "")
                return linkHost == host || linkHost.hasSuffix("." + host)
            }
            guard internalLinks else { continue }
            let block = lineBlock(list, root: root)
            guard let prev = (try? block.previousElementSibling()) ?? nil, DOM.tag(prev) == "p" else { continue }
            let before = DOM.text(prev)
            guard before.count >= 40, !before.hasSuffix(":") else { continue }
            DOM.remove(block)
        }
    }

    // MARK: Trailing tag links

    static let maxTagLinkText = 40

    /// A run of short links with nothing between them as the article's last block: a tag list (Reason's
    /// "Prediction Markets Science & Technology Utah…").
    static func removeTrailingTagLinks(_ root: Element) {
        guard let last = DOM.select(root, "p, div, span").last(where: { DOM.isConnected($0) && !DOM.text($0).isEmpty }) else { return }
        var block = last
        // The outermost wrapper that is nothing but this line; a list of links (Sources, Resources) is content.
        while let p = block.parent(), p !== root, DOM.text(p) == DOM.text(block) { block = p }
        guard DOM.closest(block, "li, ul, ol") == nil, DOM.select(block, "ul, ol").isEmpty else { return }
        let links = DOM.select(block, "a[href]")
        guard links.count >= 3, DOM.select(block, contentMedia).isEmpty,
              links.allSatisfy({ DOM.text($0).count <= maxTagLinkText }),
              links.reduce(0, { $0 + DOM.text($1).count }) >= DOM.text(block).count - links.count * 3 else { return }
        DOM.remove(block)
    }

    // MARK: End matter

    private static let endMark = P("^(?:[-–—~*]+\\s*(?:end|30)\\s*[-–—~*]+|(?:#\\s*){3,}|(?:\\*\\s*){3,})$", caseInsensitive: true)
    static let maxEndMatter = 1000

    /// Everything after `block` in the article, at every level up to the root.
    private static func removeFollowing(_ block: Element, root: Element) {
        var level: Node = block
        while level !== root {
            var s = level.nextSibling()
            while let n = s { s = n.nextSibling(); DOM.remove(n) }
            guard let up = level.parent() else { break }
            level = up
        }
    }

    /// A press release's "-end-" (or "-30-", "###") and the contact block and release number under it (NASA).
    static func removeEndMatter(_ root: Element) {
        for p in DOM.select(root, "p, div") where DOM.isConnected(p) && DOM.text(p).count <= 12 && endMark.test(DOM.text(p)) {
            let block = lineBlock(p, root: root)
            guard tailText(after: block, root: root) <= maxEndMatter else { continue }
            removeFollowing(block, root: root)
            DOM.remove(block)
            return
        }
    }

    // MARK: Subscribe tail

    private static let subscribeTail = P("^(?:subscribe (?:for|to) (?:more|my|our|the|free|updates)\\b.{0,40}|why this (?:publication|newsletter) exists|about this (?:publication|newsletter))$", caseInsensitive: true)
    static let minTextBeforeTail = 500

    /// The welcome section a Substack author pins under every post ("Subscribe for more like this", "What to
    /// expect", "Why this publication exists") and the post cards after it: the end of the page's own text. It goes
    /// with everything after it, and with a lone picture just above it.
    static func removeSubscribeTail(_ root: Element) {
        for h in DOM.select(root, "h1, h2, h3, h4") where DOM.isConnected(h) && subscribeTail.test(DOM.text(h)) {
            let block = lineBlock(h, root: root)
            let before = headText(before: block, root: root)
            guard before >= minTextBeforeTail else { continue }
            removeFollowing(block, root: root)
            if let prev = (try? block.previousElementSibling()) ?? nil, DOM.text(prev).isEmpty,
               DOM.matches(prev, "figure, div, p"), DOM.select(prev, "img").count == 1, DOM.first(prev, "figcaption") == nil {
                DOM.remove(prev)
            }
            DOM.remove(block)
            return
        }
    }

    private static func headText(before block: Element, root: Element) -> Int {
        max(0, DOM.text(root).count - DOM.text(block).count - tailText(after: block, root: root))
    }
}

extension ArticleExtraction {
    /// A members-only post whose page holds nothing but the paywall and a grid of other posts (Platformer on Ghost):
    /// with the grid gone there is no article, and the page's description is the teaser the paywall banner sits under.
    /// Only for a page that reads as walled; any other page with nothing found keeps falling back to the feed or a render.
    static func walledTeaser(_ document: Element, pageHTML: String, pageURL: String) -> String? {
        guard let description = SiteVideo.description(document) else { return nil }
        let teaser = ArticleSanitizer.sanitize(description).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teaser.isEmpty, PaywallDetection.isWalled(pageHTML: pageHTML, articleHTML: teaser, url: pageURL) else { return nil }
        return teaser
    }
}
