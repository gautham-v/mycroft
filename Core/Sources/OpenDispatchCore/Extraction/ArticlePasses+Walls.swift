import Foundation
import SwiftSoup

/// Notices, widgets and error text that are no part of the story but sit where Readability looks: a page's modal
/// dialogs (NHK's licensing notice is the whole "article" once the dialog is the best-scoring block), widgets named
/// in a `data-qa` or `data-testid` attribute rather than a class (SCMP's text-to-speech player and reading time), a
/// jobs-board box, a framework's error message left in the page (Politico's rendered copy), and a video that is
/// only a poster. `removeNotices` runs on the page before Readability.
extension ArticleExtraction {
    /// A bot check served as the page (`Verifying your device` on The Sun, Cloudflare's `Just a moment...`): a few
    /// words, no story. Unlike a login wall it is no sign of a paywall, so the page fails and the fallbacks run.
    static func isBotCheck(_ html: String) -> Bool {
        let text = ExtractionDOM.Pattern("[\\s]+").replacing(ExtractionDOM.Pattern("<[^>]+>").replacing(html, with: " "), with: " ")
        return text.count < 600 && botWall.test(text)
    }
}

extension ArticlePasses {
    static func removeNotices(_ root: Element, pageURL: String) {
        removeDialogs(root)
        isolateNHKStory(root, pageURL: pageURL)
        removeAttributeWidgets(root)
        removeBoxes(root)
        removeRenderErrors(root)
        linkPosterVideos(root)
    }

    // MARK: Dialogs

    /// A modal (consent, licensing, sign-in) is the page's, not the story's; a closed one isn't drawn at all. One that
    /// holds a headline or a page of prose is a sloppy template and stays.
    private static func removeDialogs(_ root: Element) {
        for el in DOM.select(root, "dialog") where DOM.isConnected(el) {
            if DOM.first(el, "h1") != nil || DOM.proseLen(el) >= ArticleExtraction.regionMinProse { continue }
            DOM.remove(el)
        }
    }

    // MARK: Widgets named by attribute

    /// Text-to-speech players, listen buttons and reading times, named by the page's test attributes
    /// (`TextToSpeechPlayer-Container`, `ArticleSpeechInlineWidgetArticle20-Container`, `ArticleReadingTime-Container`).
    private static let widgetAttr = P("^(?:[a-z]*-)?(?:text-?to-?speech|article-?speech|speech-?(?:inline-?)?widget|listen-?(?:button|widget)|(?:article-?)?reading-?time)", caseInsensitive: true)

    private static func removeAttributeWidgets(_ root: Element) {
        for el in DOM.select(root, "[data-qa], [data-testid], [data-test]") where DOM.isConnected(el) && !DOM.isTag(el, ["body", "html", "main", "article"]) {
            let names = ["data-qa", "data-testid", "data-test"].compactMap { DOM.attr(el, $0) }
            guard names.contains(where: { widgetAttr.test($0) }),
                  DOM.textLen(DOM.text(el)) <= maxFurnitureText, DOM.first(el, "h1") == nil else { continue }
            DOM.remove(el)
        }
    }

    // MARK: Boxes

    /// Nature's jobs board (`js-jobs-career-wrapper`: the Nature Careers logo, "Jobs" and a list of employers' logos).
    private static let jobBoard = "[class*=jobs-career], [class*=careers-widget], [class*=job-board]"

    private static func removeBoxes(_ root: Element) {
        for el in DOM.select(root, jobBoard) where DOM.isConnected(el) && DOM.textLen(DOM.text(el)) <= maxFurnitureText { DOM.remove(el) }
    }

    // MARK: Render errors

    /// A framework's error message that reached the page text (`[@portabletext/vue] Unknown block type "most-read"…`
    /// in the corner of Politico's rendered copy).
    private static let renderError = P("^\\[(?:@portabletext/[\\w-]+|vue warn|nuxt|react|next\\.?js)\\]|^unknown block type \"", caseInsensitive: true)

    private static func removeRenderErrors(_ root: Element) {
        for el in DOM.select(root, "div, p, span") where DOM.isConnected(el) {
            let text = DOM.text(el)
            guard text.count <= 300, renderError.test(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if DOM.children(el).contains(where: { DOM.isTag($0, ["div", "p", "figure", "img"]) }) { continue }
            DOM.remove(el)
        }
    }

    // MARK: Poster-only videos

    private static let posterSize = P("/resize/\\d+/")

    /// A video card whose player the page draws with script (Politico's Brightcove `site-video-<id>`: a poster, a play
    /// button and a link to the video's page under it) arrives as a 270px poster that looks dead. The poster is
    /// drawn at article width and links to the video's page, with its title as the caption.
    private static func linkPosterVideos(_ root: Element) {
        for card in DOM.select(root, "aside[data-testid^=site-video-]") where DOM.isConnected(card) {
            guard DOM.first(card, "video, iframe, source") == nil, let img = DOM.first(card, "img.video-poster, img[src]"),
                  let src = DOM.attr(img, "src") ?? DOM.attr(img, "data-src") else { continue }
            var scope = card.parent()
            var link: Element?
            for _ in 0..<3 {
                guard let s = scope, s !== root else { break }
                link = DOM.select(s, "a[href*=\"/video/\"]").first(where: { DOM.textLen(DOM.text($0)) > 0 })
                if link != nil { break }
                scope = s.parent()
            }
            guard let target = scope, let link, target !== root, let href = DOM.attr(link, "href") else { continue }
            let title = DOM.escapeHTML(DOM.text(link))
            let big = posterSize.replacing(src, with: "/resize/1200/")
            DOM.replace(target, withHTML: "<figure><a href=\"\(DOM.escapeHTML(href))\"><img src=\"\(DOM.escapeHTML(big))\" alt=\"\(title)\"></a><figcaption><a href=\"\(DOM.escapeHTML(href))\">\(title)</a></figcaption></figure>")
        }
    }

    // MARK: NHK (site-specific)

    private static let nhkPromo = P("^NHK ONE\\s*ニュース・防災アプリ$")
    /// NHK cuts the copy it serves mid-word and marks the cut with a letter and an ellipsis ("N…").
    private static let cutOff = P("^\\S{1,2}…$")

    /// NHK's news site (news.web.nhk, once www3.nhk.or.jp/news) is a Next.js app: the page it serves holds the lede and
    /// the rest loads from an API that refuses other clients, and the lede is a paragraph or two, too little for
    /// Readability, which then keeps the page (logo, menu, "深掘りコンテンツ" cards). The headline, the picture above
    /// it and the paragraphs under it, up to the first card, are the story; the app's promo line and the cut mark go.
    private static func isolateNHKStory(_ root: Element, pageURL: String) {
        guard let host = DOM.hostname(pageURL)?.lowercased(), host.hasSuffix("nhk.or.jp") || host.hasSuffix(".nhk"),
              let body = DOM.first(root, "body"), let main = DOM.first(body, "main"), DOM.first(main, "h1") != nil else { return }
        var title = "", picture = "", paragraphs: [String] = []
        var seenTitle = false
        for el in DOM.select(main, "h1, img, p") {
            if DOM.tag(el) == "h1" { title = DOM.outerHTML(el); seenTitle = true; continue }
            if DOM.tag(el) == "img" { if !seenTitle, picture.isEmpty { picture = "<p>" + DOM.outerHTML(el) + "</p>" }; continue }
            guard seenTitle else { continue }
            var inCard = false
            var up = el.parent()
            while let u = up, u !== main { if DOM.isTag(u, ["a", "li", "button", "nav"]) { inCard = true; break }; up = u.parent() }
            if inCard { break }
            let text = DOM.text(el).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || nhkPromo.test(text) || cutOff.test(text) || DOM.first(el, "time") != nil { continue }
            paragraphs.append(DOM.outerHTML(el))
        }
        guard !paragraphs.isEmpty else { return }
        _ = try? body.html("<article>" + title + picture + paragraphs.joined() + "</article>")
    }
}
