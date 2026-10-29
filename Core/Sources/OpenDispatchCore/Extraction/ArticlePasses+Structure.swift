import Foundation
import SwiftSoup

/// Content and structure that blogs and publishing platforms hide from Readability: a post kept in a script template,
/// a story collapsed behind "Read more", headings its class or wrapper gets cleaned away with, a page that is one picture.
extension ArticlePasses {
    /// Runs first in `prepare`: the passes that put content back before the interface passes remove buttons and labels.
    static func prepareStructure(_ root: Element) {
        unpackTemplates(root)
        revealCollapsedText(root)
        removeBreadcrumbs(root)
        keepHeadings(root)
    }

    // MARK: unpackTemplates

    private static let templateScript = "script[type=\"text/template\"], script[type=\"text/x-template\"]"
    static let minTemplateText = 400

    /// A post a script template holds, with a <noscript> copy beside it (Blogger's post-content): the page's script
    /// draws it, so it is no element for Readability, which then picks a reader comment. The template's markup takes
    /// its place and the duplicate goes. Page templates ({{ }}, <% %>) and short ones stay.
    static func unpackTemplates(_ root: Element) {
        for script in DOM.select(root, templateScript) where DOM.isConnected(script) {
            let html = script.data()
            guard DOM.textLen(DOM.plainText(html)) >= minTemplateText, !html.contains("{{"), !html.contains("<%") else { continue }
            if let next = try? script.nextElementSibling(), DOM.tag(next) == "noscript" { DOM.remove(next) }
            DOM.replace(script, withHTML: html)
        }
    }

    // MARK: revealCollapsedText

    private static let expandLabel = P("^(?:read|show|see|view)\\s+(?:more|less|all|full)|^(?:more|expand)$", caseInsensitive: true)
    static let minCollapsedProse = 100

    /// A description folded behind a "Read more" button is marked aria-hidden until it is opened (France 24's video
    /// pages: the whole summary sits in `.m-box-expand__content`), and Readability drops aria-hidden blocks as
    /// invisible. The text is real: the mark goes when a block holding prose has such a button beside it.
    static func revealCollapsedText(_ root: Element) {
        for el in DOM.select(root, "[aria-hidden=true]") where DOM.isConnected(el) && !DOM.isTag(el, ["span", "i", "svg", "img", "picture"]) {
            guard DOM.proseLen(el) >= minCollapsedProse, let box = el.parent(),
                  DOM.children(box).contains(where: { DOM.matches($0, "button, [role=button]") && expandLabel.test(DOM.text($0)) }) else { continue }
            DOM.removeAttr(el, "aria-hidden")
        }
    }

    // MARK: removeBreadcrumbs

    private static let breadcrumb = P("breadcrumbs?", caseInsensitive: true)
    static let maxBreadcrumbText = 200

    /// "Home / Americas" trails: a nav or list named for them, short and with no paragraph in it. They would draw as a
    /// numbered list above the story.
    static func removeBreadcrumbs(_ root: Element) {
        for el in DOM.select(root, "nav, ol, ul") where DOM.isConnected(el) {
            let name = (DOM.attr(el, "aria-label") ?? "") + " " + DOM.classTokens(el).joined(separator: " ")
            guard breadcrumb.test(name), DOM.textLen(DOM.text(el)) <= maxBreadcrumbText, DOM.first(el, "p") == nil else { continue }
            DOM.remove(el)
        }
    }

    // MARK: keepHeadings

    private static let headingWrapper: Set<String> = ["div", "span", "section"]
    /// What may sit beside the heading in such a wrapper: icons, buttons, an empty link or span. A box with a further
    /// block, a script or a player in it is a module (an ad slot, "Watch on Deadline") that Readability rightly drops.
    private static let headingCompanion: Set<String> = ["a", "span", "button", "svg", "i"]
    private static let headerWord = P("header", caseInsensitive: true)

    /// A class token that trips Readability's word lists only through "header".
    private static func headerOnly(_ token: String) -> Bool {
        readabilityJunk(token) && !readabilityJunk(headerWord.replacing(token, with: ""))
    }

    /// Readability loses headings three ways, all by what surrounds them: a class like "header" makes the heading an
    /// unlikely candidate (Stack Overflow's `h2.header` with its permalink anchor), and a block holding nothing but the
    /// heading and an icon or an empty link has no text for its cleanup to count and is removed with it (Eater's
    /// restaurant names beside a save button, Ghostty's jump-link headers). The heading loses its "header" class, and
    /// takes the place of wrappers that hold only it. h1 stays where it is: the headline region is found from it.
    static func keepHeadings(_ root: Element) {
        for h in DOM.select(root, "h2, h3, h4, h5, h6") where DOM.isConnected(h) {
            let words = DOM.text(h)
            guard !words.isEmpty else { continue }
            dropClassTokens(h, headerOnly)
            for anchor in DOM.select(h, "a[aria-hidden=true]") where DOM.text(anchor).isEmpty { DOM.remove(anchor) }
            var top: Element = h
            while let parent = top.parent(), DOM.isTag(parent, headingWrapper), DOM.text(parent) == words,
                  DOM.children(parent).allSatisfy({ $0 === top || (DOM.isTag($0, headingCompanion) && DOM.first($0, "img, picture, video, iframe, script, div") == nil) }),
                  DOM.classTokens(parent).allSatisfy({ !readabilityJunk($0) || headerOnly($0) }) {
                top = parent
            }
            // A card's title is a link (related stories), and a section header's title belongs to its module: both
            // stay with the wrapper Readability drops them with.
            // A heading in the article's own run is followed by its text: a card title is followed by the card's meta.
            guard top !== h, DOM.first(h, "a[href]") == nil, top.parent().map({ !DOM.isTag($0, ["header", "hgroup"]) }) == true,
                  (try? top.nextElementSibling()).map(isContentBlock) == true else { continue }
            _ = try? top.before(h)
            DOM.remove(top)
        }
    }

    private static let contentBlock: Set<String> = ["p", "ul", "ol", "pre", "blockquote", "table", "figure", "dl"]

    /// Text, a list, code, a quote, a table or a figure: or another heading, bare or in a wrapper of its own.
    private static func isContentBlock(_ el: Element) -> Bool {
        if DOM.isTag(el, contentBlock) || DOM.isTag(el, DOM.headingTags) { return true }
        guard let h = DOM.select(el, "h2, h3, h4, h5, h6").first else { return false }
        return DOM.text(el) == DOM.text(h)
    }

    // MARK: pictureStory

    static let maxPictureProse = 200
    static let maxPictureFigures = 4

    /// A page whose story is a picture (The New Yorker's Daily Cartoon: one figure and its credit, no paragraph): the
    /// figures of the headline's article, or nil when it has prose, no figure or a big image only as decoration. Taken
    /// before Readability, which has nothing to score on such a page and keeps its footer instead.
    static func pictureStory(_ document: Element) -> String? {
        guard let h1 = ArticleExtraction.headline(document), let box = DOM.closest(h1, "article, main"),
              DOM.proseLen(box) < maxPictureProse else { return nil }
        let figures = DOM.select(box, "figure").filter { fig in
            DOM.closest(fig, "nav, aside, header, footer") == nil && !DOM.contains(fig, h1)
                && DOM.select(fig, "img").contains { !isTinyImg($0) && !isLogo($0) }
        }
        guard (1...maxPictureFigures).contains(figures.count) else { return nil }
        // The figure's own controls (a cartoon's "Copy link" and "Shop" buttons, a "Link copied" pop-up) are no part of it.
        for fig in figures {
            for el in DOM.select(fig, "button, [role=dialog], [aria-hidden=true]:not(svg)") where DOM.isConnected(el) && DOM.first(el, "img, picture") == nil { DOM.remove(el) }
        }
        return figures.map(DOM.outerHTML).joined()
    }

    /// Whether the extraction already has the first picture of `figures` (matched by file name).
    static func containsPicture(_ html: String, of figures: String) -> Bool {
        DOM.withFragment(figures) { body -> Bool in
            guard let src = DOM.first(body, "img").flatMap({ DOM.attr($0, "src") ?? DOM.attr($0, "data-src") }),
                  let name = URL(string: src)?.lastPathComponent, !name.isEmpty else { return true }
            return html.contains(name)
        } ?? true
    }
}
