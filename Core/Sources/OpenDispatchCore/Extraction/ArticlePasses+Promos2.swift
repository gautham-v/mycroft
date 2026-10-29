import Foundation
import SwiftSoup

/// Promos and recirculation the first rounds kept: modules titled "Related posts", "Explore more from GitHub", "Deals
/// of the Day", "More maps in Eater" (on the page, while the cards are still under their title); recirculation boxes by
/// class (Vox's `duet--recirculation--*`, Metro's `metro-more-from`, Condé Nast's `link-stack`); donation and subscribe
/// boxes; follow-us-on-Google lines; titled teaser lists, call-to-action headings, newsletter forms and labelled links
/// left in the article; banner pictures; affiliate tiles; "End of Article" and its author card.
extension ArticlePasses {
    // MARK: Before Readability

    static func removePromoModules(_ root: Element) {
        removeTitledModules(root)
        removeRecirculationBoxes(root)
        removeDonationBoxes(root)
    }

    /// Titles of a module of links to other pages, beyond `recircTitle`: "Related posts" (GitHub, DeepMind),
    /// "Explore more from GitHub", "More maps in Eater", "Deals of the Day" (Metro), "People are also reading…" (Lee),
    /// "Go deeper with TH Premium", "More From This Series" (Vulture), "More editor-approved picks" (Bon Appétit),
    /// "More Parenting Advice From Slate", "More on Google Home:" (9to5).
    static let promoTitle = P("^(?:related(?: posts| guides| maps| videos| reading)?|related to this story|explore more(?: from [^.]{1,40})?|more (?:[\\p{L}'’-]+ ){0,3}(?:in|from|on) [^.]{1,40}|more from this series|more (?:maps|guides|videos|recipes|reviews)|more (?:[\\p{L}-]+ )?(?:editor['’]?s?[- ]approved |editors['’]? )?picks|deals? of the day|people are also reading(?:…|\\.\\.\\.)?|go deeper(?: with [^.]{1,40})?|keep reading|what to read next)\\s*:?$", caseInsensitive: true)

    static func isPromoTitle(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 60 && (promoTitle.test(t) || recircTitle.test(t))
    }

    private static let titleClass = P("title|header|heading|eyebrow|label|kicker", caseInsensitive: true)
    static let maxModuleText = 3000
    static let maxCardBlurb = 200

    /// A title with a box of cards under it: the box goes. On the page the title still sits in its module, which
    /// Readability may later split from the cards (GitHub's "Related posts" heading was dropped and its cards kept).
    /// The box has links and little prose of its own; a "Related" heading over a section of the story stays.
    static func removeTitledModules(_ root: Element) {
        let candidates = DOM.select(root, "h2, h3, h4, h5, h6, [class]").filter { el in
            if DOM.isTag(el, DOM.headingTags) { return true }
            guard DOM.classTokens(el).contains(where: { titleClass.test($0) }), DOM.isTag(el, ["div", "span", "p", "strong"]) else { return false }
            return DOM.children(el).allSatisfy { DOM.isTag($0, ["span", "a", "strong", "b", "em", "svg"]) }
        }
        for title in candidates where DOM.isConnected(title) {
            let t = DOM.text(title)
            // Ghost's "Read more" grid stays for Readability to pick on a walled post, where it stands for "no
            // article" (`walledTeaser`); with it gone the sign-in bar would be taken for the story.
            guard isPromoTitle(t), !t.lowercased().hasPrefix("read more") else { continue }
            var head = title
            while let p = head.parent(), DOM.text(p) == t, !DOM.isTag(p, ["body", "main", "article"]) { head = p }
            guard let box = head.parent(), !DOM.isTag(box, ["body", "main", "article", "html"]), box !== root,
                  DOM.text(box).hasPrefix(t), DOM.first(box, "h1") == nil else { continue }
            let text = DOM.text(box)
            guard text.count <= maxModuleText else { continue }
            let links = DOM.select(box, "a[href]").filter { !DOM.contains(head, $0) }
            guard links.count >= 2 || (links.count == 1 && DOM.select(box, "img").count >= 1) else { continue }
            let linked = links.reduce(0) { $0 + DOM.text($1).count }
            let rest = max(0, text.count - t.count)
            // A bare "Related" over prose is a section of the story.
            if rest - linked > 1200 || (rest > 600 && Double(linked) < 0.3 * Double(rest)) { continue }
            // Cards carry a line of blurb at most; a paragraph of prose is the story's.
            if DOM.select(box, "p").contains(where: { DOM.text($0).count > maxCardBlurb && !isLinkDense($0) }) { continue }
            DOM.remove(box)
        }
    }

    /// A class naming recirculation inside it (Vox Media's `duet--recirculation--map-footer-recirc`), Metro's
    /// `metro-more-from` carousels, Condé Nast's `link-stack` lists after the story, Us Weekly's `link-related` cards.
    private static let recircToken = P("(?:^|[-_])(?:recirc|recirculation|more-from|link-?stack|link-related)(?:[-_]|$)", caseInsensitive: true)

    static func removeRecirculationBoxes(_ root: Element) {
        for el in DOM.select(root, "[class]") where DOM.isConnected(el) && !DOM.isTag(el, ["html", "body", "main", "article", "a"]) {
            guard DOM.classTokens(el).contains(where: { recircToken.test($0) }) else { continue }
            var box = el
            // One item of a link stack takes its list.
            if DOM.tag(el) == "li", let list = el.parent(), DOM.isTag(list, ["ul", "ol"]) { box = list }
            guard DOM.text(box).count <= maxModuleText, DOM.first(box, "h1") == nil, DOM.first(box, "a[href]") != nil else { continue }
            // Links, not a short story inside a wrapper that happens to carry the class.
            let linked = DOM.select(box, "a[href]").reduce(0) { $0 + DOM.text($1).count }
            guard Double(linked) >= 0.4 * Double(DOM.text(box).count) || DOM.select(box, "p").allSatisfy({ DOM.text($0).count <= 250 }) else { continue }
            DOM.remove(box)
        }
    }

    /// PBS's "A free press is a cornerstone of a healthy democracy… Donate now": a short box whose button asks for
    /// money. The button is what marks it; a paragraph mentioning a donation link stays.
    private static let donateButton = P("^(?:donate|give|contribute|support us)(?: now| today| here)?$", caseInsensitive: true)
    private static let donateHref = P("donat|//give\\.|/give\\b|/contribute\\b|/support-?us\\b", caseInsensitive: true)
    static let maxDonationBox = 400

    static func removeDonationBoxes(_ root: Element) {
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) {
            guard donateHref.test(DOM.attr(a, "href") ?? ""), donateButton.test(DOM.text(a)) else { continue }
            var box: Element = a
            while let p = box.parent(), p !== root, !DOM.isTag(p, ["body", "main", "article", "html"]), DOM.text(p).count <= maxDonationBox { box = p }
            if box !== a { DOM.remove(box) }
        }
    }

    // MARK: After Readability

    /// On the cleaned article, after icons are gone (Metro's arrow `<svg><title>Arrow</title>` read as text before).
    static func removePromoText(_ root: Element, base: String?) {
        removeGoogleFollow(root)
        removeTitledTeasers(root)
        removeCallToActionBoxes(root)
        removePromoLines2(root)
        removeLabelledLinks2(root)
        removeBannerImages(root)
        removeAffiliateTiles(root)
        removeEndOfArticle(root)
        removeVideoCardLeftovers(root)
        removeTrailingTagLabels(root)
        removeTrailingLinkLists(root, base: base)
        for hr in DOM.select(root, "hr") where DOM.isConnected(hr) && nextContent(hr, root: root) == nil { DOM.remove(hr) }
    }

    // MARK: Follow on Google

    /// "Follow TechRadar on Google News…", Tom's Hardware's, Android Authority's "Add … on Google:", the Mirror's "make
    /// us your preferred source": a pitch to follow the site in Google's feeds, often with a "Click to follow" picture
    /// linking to the same place.
    private static let googleFollowHref = P("^https?://(?:news\\.google\\.com/publications/|(?:www\\.)?google\\.com/preferences/source)", caseInsensitive: true)
    private static let googleFollowText = P("\\b(?:on google news|preferred source|(?:add|follow) [^.]{1,40} on google\\b|(?:never miss a story|find (?:us|them) easily)[^.]{0,80}\\bgoogle\\b)", caseInsensitive: true)
    static let maxGoogleFollow = 320

    static func removeGoogleFollow(_ root: Element) {
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) && googleFollowHref.test(DOM.attr(a, "href") ?? "") {
            // The sentence around the link, not just the link ("Follow TechRadar on Google News and … in your feeds").
            let block = lineBlock(DOM.closest(a, "p, li") ?? a, root: root)
            if DOM.text(block).count <= maxGoogleFollow { DOM.remove(block) }
        }
        for p in DOM.select(root, "p, li") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.count <= maxGoogleFollow, googleFollowText.test(t), t.lowercased().contains("google") else { continue }
            DOM.remove(lineBlock(p, root: root))
        }
    }

    // MARK: Titled teasers

    private static let bylineLine = P("^by\\s+\\S.{0,100}$", caseInsensitive: true)

    /// A card under a promo title: a teaser, a byline under a teaser's link (PBS's "By Hallie Golden, Associated
    /// Press"), or an excerpt that ends in a link to the rest (Slate's "More Parenting Advice").
    static func isPromoCard(_ el: Element, below level: Int) -> Bool {
        if isTeaser(el, below: level) { return true }
        let tag = DOM.tag(el)
        let text = DOM.text(el)
        if tag == "p" {
            if bylineLine.test(text) || isDateLine(text) { return true }
            if let last = el.getChildNodes().last(where: { !(($0 as? TextNode).map { DOM.squash($0.getWholeText()).isEmpty } ?? false) }) as? Element,
               DOM.tag(last) == "a", DOM.text(last).count >= 20, text.count <= 900 { return true }
            return false
        }
        guard ["li", "div", "ul", "ol", "article", "section"].contains(tag), !DOM.children(el).isEmpty else { return false }
        return DOM.children(el).allSatisfy { isPromoCard($0, below: level) }
    }

    /// A promo title (heading or a line standing for one) with cards after it: both go. One with nothing after it in
    /// the article goes too; one before prose stays, since "Related" or "More on X" may head a section of the story.
    static func removeTitledTeasers(_ root: Element) {
        for h in DOM.select(root, "h1, h2, h3, h4, h5, h6, p, div") where DOM.isConnected(h) {
            let t = DOM.text(h)
            guard isPromoTitle(t) else { continue }
            if !DOM.isTag(h, DOM.headingTags), !DOM.children(h).allSatisfy({ DOM.isTag($0, ["strong", "b", "span", "em"]) }) { continue }
            let head = lineBlock(h, root: root)
            let level = DOM.isTag(h, DOM.headingTags) ? Int(DOM.tag(h).dropFirst()) ?? 2 : 2
            var run: [Element] = []
            var next = (try? head.nextElementSibling()) ?? nil
            while let sib = next, isPromoCard(sib, below: level) {
                run.append(sib)
                next = (try? sib.nextElementSibling()) ?? nil
            }
            guard !run.isEmpty || nextContent(head, root: root) == nil else { continue }
            // The card's picture can sit above its label (TV Insider: linked picture, "Related", headline).
            if !run.isEmpty, let prev = (try? head.previousElementSibling()) ?? nil, isLinkedPicture(prev) { DOM.remove(prev) }
            for el in run { DOM.remove(el) }
            DOM.remove(head)
        }
    }

    /// A picture and nothing else, inside a link.
    private static func isLinkedPicture(_ el: Element) -> Bool {
        DOM.text(el).isEmpty && DOM.select(el, "img").count == 1 && DOM.first(el, "a[href] img") != nil && DOM.first(el, "figcaption") == nil
    }

    // MARK: Calls to action

    /// Headings that ask the reader to do something other than read: the BBC's "Get in touch", the New York Post's
    /// "Download The California Post App, follow us on social…", Metro's "Ask Metro" AI box, Scientific American's
    /// "On supporting science journalism", People's "VIPs Get More", the Daily Beast's "Sign up to receive news…",
    /// Lee's "Be the first to know", Metro's "The Soaps Newsletter – Weekly".
    private static let ctaTitle = P("^(?:get in touch|download (?:the|our) [^.]{1,60}\\bapp\\b.*|ask metro|on supporting science journalism|vips get more|sign up (?:to receive|for) [^.]{1,80}|be the first to know|get the best of [^.]{1,30}|[\\p{L}'’ ]{0,30}newsletter(?:\\s*[–—-]\\s*[\\p{L} ]{1,20})?)$", caseInsensitive: true)
    private static let newsletterOnly = P("newsletter(?:\\s*[–—-]\\s*[\\p{L} ]{1,20})?$", caseInsensitive: true)
    static let maxCallToAction = 900

    /// The heading's box goes when it is no more than the pitch; otherwise the heading and the short lines after it
    /// that belong to it (link lists, one or two sentences) go.
    static func removeCallToActionBoxes(_ root: Element) {
        for h in DOM.select(root, "h2, h3, h4, h5, h6, p, strong") where DOM.isConnected(h) {
            let t = DOM.text(h)
            guard !t.isEmpty, t.count <= 120, ctaTitle.test(t) else { continue }
            if !DOM.isTag(h, DOM.headingTags), DOM.isTag(h, ["p"]), !DOM.children(h).allSatisfy({ DOM.isTag($0, ["strong", "b", "span", "em"]) }) { continue }
            let head = lineBlock(h, root: root)
            if let box = head.parent(), box !== root, DOM.text(box).count <= maxCallToAction, DOM.select(box, "p").allSatisfy({ DOM.text($0).count <= 400 }),
               DOM.first(box, "img, picture, video, iframe") == nil, (try? box.previousElementSibling()) != nil || (try? box.nextElementSibling()) != nil {
                DOM.remove(box)
                continue
            }
            // A newsletter's title only in its own box: "The newsletter" may head a section of a story about one.
            if newsletterOnly.test(t) { continue }
            // The pitch's one sentence (it links somewhere) and its link lists, up to a rule (Scientific American
            // frames it with two). The story's next line, linkless, stays (the Daily Beast's sign-up title).
            var total = 0
            var first = true
            var next = (try? head.nextElementSibling()) ?? nil
            while let sib = next, !DOM.isTag(sib, DOM.headingTags), DOM.first(sib, "img, picture, video, iframe") == nil {
                if DOM.tag(sib) == "hr" { DOM.remove(sib); break }
                let n = DOM.text(sib).count
                guard total + n <= maxCallToAction * 2, (isLinkDense(sib) && n <= 1200) || (first && n <= 400 && DOM.first(sib, "a[href]") != nil) else { break }
                total += n
                first = false
                next = (try? sib.nextElementSibling()) ?? nil
                DOM.remove(sib)
            }
            if let prev = (try? head.previousElementSibling()) ?? nil, DOM.tag(prev) == "hr" { DOM.remove(prev) }
            DOM.remove(head)
        }
    }

    // MARK: Promo lines

    /// Whole lines that are the site talking: io9's "Want more io9 news? Check out…", newsletter form leftovers
    /// (the Express' "Invalid email" and consent text), news-tip appeals (Investopedia, Fox's "GOT A TIP?"), ad-slot
    /// labels (The Register's "REG AD"), Slate's "Video from Slate" placeholder, Macworld's empty "Best Prices Today:",
    /// People's "Never miss a story — sign up for … newsletter", hashnode's empty comment widget, The Ringer's "More on
    /// the NBA" carousel labels.
    private static let promoLines2 = [
        P("^want more [^?]{1,40}\\?\\s*(?:check out|sign up|subscribe|follow|head (?:over )?to|visit)\\b.{0,220}$", caseInsensitive: true),
        P("^(?:invalid email(?: address)?|you agree you are 18 or over\\b.{0,400}|i would like to receive emails from\\b.{0,300})$", caseInsensitive: true),
        P("^(?:do you have|got) a (?:news )?tip\\b.{0,120}$", caseInsensitive: true),
        P("^reg ad$", caseInsensitive: true),
        P("^video from [\\p{L} ]{1,20}$", caseInsensitive: true),
        P("^(?:best|lowest) prices? today:?$", caseInsensitive: true),
        P("^never miss a (?:story|thing)\\b.{0,60}\\bnewsletter\\b.{0,200}$", caseInsensitive: true),
        P("^(?:no comments yet\\b.{0,40}|join the discussion)$", caseInsensitive: true),
        // E! Online's "For the latest breaking news updates, click here to download the E! News App".
        P("^(?:for the latest [^,]{1,60}, )?(?:click here to )?download (?:the|our) [^.]{1,40}\\bapp\\.?$", caseInsensitive: true),
        // Apple Newsroom's "Stay up to date with the latest articles from Apple Newsroom."
        P("^stay up to date with the latest (?:articles|stories|news) from [^.]{1,40}\\.?$", caseInsensitive: true),
    ]
    private static let carouselLabel = P("^more on (?:the )?[\\p{L}'’ ]{1,30}$", caseInsensitive: true)

    static func removePromoLines2(_ root: Element) {
        for el in DOM.select(root, "p, li, span, a, div") where DOM.isConnected(el) {
            let t = DOM.text(el)
            guard !t.isEmpty, t.count <= 500 else { continue }
            if DOM.isTag(el, ["span", "a", "div"]) {
                // A span or link only when it is the whole line, or stands as a line of its own in a box (hashnode's
                // "Join the discussion" link under its heading), never a part of a sentence.
                let inLine = el.parent().map { DOM.isTag($0, ["p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "figcaption", "td", "a", "span", "em", "strong", "b", "i"]) } ?? true
                guard lineBlock(el, root: root) !== el || DOM.tag(el) == "div" || !inLine,
                      DOM.children(el).allSatisfy({ !DOM.isTag($0, ["p", "div", "ul", "ol", "figure"]) }) else { continue }
            }
            let hit = promoLines2.contains { $0.test(t) } || (carouselLabel.test(t) && DOM.first(el, "a[href]") == nil && !DOM.isTag(el, ["li", "a"]))
            guard hit else { continue }
            // A sign-up form's box goes whole, with its blurb (the Express' "Get the latest politics news - straight
            // from our team in Westminster and more").
            let block = lineBlock(el, root: root)
            if signUpForm.test(t), let box = block.parent(), box !== root, DOM.text(box).count <= maxSignUpForm, DOM.first(box, "img, picture, video, iframe") == nil {
                DOM.remove(box)
            } else {
                dropBlock(el, root: root)
            }
        }
    }
    private static let signUpForm = P("^(?:invalid email|you agree you are 18|i would like to receive emails)", caseInsensitive: true)
    static let maxSignUpForm = 1000

    // MARK: Labelled links

    /// "Read" and "More" alone count only with a colon: "Read <a>the full report</a>" points at the story's source.
    private static let linkLabel2 = P("^(?:(?:read more|read also|also read|see also|related|go deeper)\\s*:?|(?:read|more)\\s*:)$", caseInsensitive: true)

    /// "READ MORE: <story>" (PBS, the label inside the link), "MORE: <story>" (Metro), "Read more<story>" (France 24,
    /// the label in its own span with no colon): a label and one link to another story, nothing else.
    static func removeLabelledLinks2(_ root: Element) {
        for p in DOM.select(root, "p, li") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.count <= 260 else { continue }
            let links = DOM.select(p, "a[href]")
            guard links.count == 1 else { continue }
            let link = links[0]
            let label: String
            if let strong = DOM.first(link, "strong, b"), DOM.text(link).hasPrefix(DOM.text(strong)) {
                label = DOM.text(strong)
            } else {
                label = DOM.squash(t.replacingOccurrences(of: DOM.text(link), with: ""))
            }
            guard linkLabel2.test(label), DOM.text(link).count - (DOM.text(link).hasPrefix(label) ? label.count : 0) >= 15 else { continue }
            DOM.remove(lineBlock(p, root: root))
        }
    }

    // MARK: Pictures

    /// A picture that says it is a banner or a section header: the BBC's newsletter strip ("Thin, red banner promoting
    /// the Politics Essential newsletter"), "Your Voice banner image", TechRadar's "Best antivirus software header".
    /// Captionless only.
    private static let bannerAlt = P("\\bbanner (?:image|promoting|for|advertising)\\b|(?:^|\\s)(?:banner|header)(?: image| graphic)?\\.?$", caseInsensitive: true)

    static func removeBannerImages(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) && bannerAlt.test(DOM.squash(DOM.attr(img, "alt"))) {
            let fig = DOM.closest(img, "figure")
            if let fig, let cap = DOM.first(fig, "figcaption"), !DOM.text(cap).isEmpty { continue }
            let block = lineBlock(fig ?? img, root: root)
            guard DOM.text(block).isEmpty, block === img || DOM.select(block, "img").count == 1 else { continue }
            DOM.remove(block)
        }
    }

    /// Us Weekly's "Deal of the Day" tile: a picture linking to an affiliate redirect (`o.bttn.io`) with no words.
    private static let affiliateRedirect = P("^https?://(?:[\\w-]+\\.)*(?:bttn\\.io|amzn\\.to|geni\\.us|shop-links\\.co|prf\\.hn|howl\\.me|go\\.redirectingat\\.com|go\\.skimresources\\.com)/", caseInsensitive: true)

    static func removeAffiliateTiles(_ root: Element) {
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) && affiliateRedirect.test(DOM.attr(a, "href") ?? "") {
            guard DOM.first(a, "img") != nil, DOM.text(a).isEmpty else { continue }
            let block = lineBlock(a, root: root)
            if DOM.text(block).isEmpty { DOM.remove(block) }
        }
    }

    // MARK: End of article

    private static let endOfArticle = P("^end of (?:the )?(?:article|story)$", caseInsensitive: true)

    /// Times Now closes with the author's card and "End of Article": both go (the app draws the byline).
    static func removeEndOfArticle(_ root: Element) {
        for p in DOM.select(root, "p, div, span") where DOM.isConnected(p) && endOfArticle.test(DOM.text(p)) {
            let block = lineBlock(p, root: root)
            if let box = block.parent(), box !== root, DOM.text(box).count <= 700, DOM.select(box, "img").count <= 1 {
                DOM.remove(box)
            } else {
                DOM.remove(block)
            }
        }
    }

    // MARK: Video cards

    private static let coverCaption = P("^cover image\\b", caseInsensitive: true)
    private static let durationOnly = P("^\\d{1,2}(?::\\d{2}){1,2}$")

    /// France 24's video cards without their player: a poster captioned "Cover image: … © FRANCE 24" with the
    /// duration ("03:46") under it, and the video's title line just above. Nothing in it plays.
    static func removeVideoCardLeftovers(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            guard let cap = DOM.first(fig, "figcaption"), coverCaption.test(DOM.text(cap)),
                  DOM.select(fig, "p").contains(where: { durationOnly.test(DOM.text($0)) }) else { continue }
            var block = lineBlock(fig, root: root)
            while let up = block.parent(), up !== root, DOM.children(up).count == 1 { block = up }
            if let prev = (try? block.previousElementSibling()) ?? nil, DOM.tag(prev) == "p", DOM.text(prev).count <= 120,
               DOM.first(prev, "a[href], img") == nil, block.parent().map({ DOM.children($0).count <= 3 }) ?? false {
                DOM.remove(prev)
            }
            DOM.remove(block)
        }
    }

    // MARK: Trailing labels

    /// A tag list's label left after its tags were dropped (TechRadar's "CATEGORIES", France 24's "Keywords for this
    /// article", Investopedia's "Partner Links"): only as the article's last line.
    private static let trailingLabel = P("^(?:categories|topics|tags|keywords for this article|partner links)$", caseInsensitive: true)

    static func removeTrailingTagLabels(_ root: Element) {
        for el in DOM.select(root, "p, div, span, h2, h3, h4").reversed() where DOM.isConnected(el) {
            guard trailingLabel.test(DOM.text(el)) else { continue }
            let block = lineBlock(el, root: root)
            if nextContent(block, root: root) == nil { dropBlock(block, root: root) }
        }
    }

    // MARK: Trailing link lists

    private static let taxonomyPath = P("/(?:tags?|topics?|categor(?:y|ies)|all-about|keywords?|subjects?)/", caseInsensitive: true)
    private static let articlePath = P("/\\d{4}/\\d{1,2}/|\\.html?(?:$|[?#])|-\\d{5,}(?:$|[/?#])", caseInsensitive: true)
    static let maxTrailingList = 8

    /// The article's last block is a list that only points elsewhere: tag chips (Business Insider's "Google, Alphabet,
    /// AI, More…", the Mirror's /all-about/ topics, a one-item category) or a run of same-site headlines after the last
    /// paragraph (cleveland.com's related recalls). A list under a heading or after "Sources:" is the story's own.
    static func removeTrailingLinkLists(_ root: Element, base: String?) {
        let host = base.flatMap { DOM.hostname($0) }.map { $0.lowercased().replacingOccurrences(of: "www.", with: "") }
        while let list = DOM.select(root, "ul, ol").last(where: { DOM.isConnected($0) && hasMediaOrText($0) }) {
            let block = lineBlock(list, root: root)
            guard nextContent(block, root: root) == nil, DOM.closest(block, "li") == nil else { return }
            let items = DOM.children(list).filter { DOM.tag($0) == "li" && hasMediaOrText($0) }
            guard !items.isEmpty, items.count <= maxTrailingList, DOM.first(list, "img, picture, figure") == nil else { return }
            let tags = items.allSatisfy { li in
                let t = DOM.text(li)
                guard t.count <= 40 else { return false }
                guard let a = DOM.first(li, "a[href]") else { return t.count <= 12 }
                return taxonomyPath.test(DOM.attr(a, "href") ?? "")
            } && items.contains { DOM.first($0, "a[href]") != nil }
            var headlines = false
            if !tags, let host, items.count >= 3, let prev = (try? block.previousElementSibling()) ?? nil, DOM.tag(prev) == "p", !DOM.text(prev).hasSuffix(":") {
                headlines = items.allSatisfy { li in
                    guard let a = DOM.first(li, "a[href]"), DOM.text(a) == DOM.text(li), DOM.text(li).count >= 25, let href = DOM.attr(a, "href"),
                          let h = DOM.hostname(href)?.lowercased().replacingOccurrences(of: "www.", with: "") else { return false }
                    return (h == host || h.hasSuffix("." + host)) && articlePath.test(href)
                }
            }
            guard tags || headlines else { return }
            DOM.remove(block)
        }
    }
}
