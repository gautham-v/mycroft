import Foundation
import SwiftSoup

/// Reference and technical pages: wikis, API docs, papers, READMEs. Their markup keeps what a reader of the page
/// doesn't want in a story (citation lists, edit links, navboxes, permalink pilcrows, LaTeX source beside the math) and
/// loses what Readability's cleanup misjudges (short headings with an "edit" link beside them, an intro paragraph in the
/// page header). One pass per generator, found by its markup, not by address, so mirrors and other sites on the same
/// software get the same treatment.
extension ArticlePasses {
    // MARK: Entry points

    /// Before Readability (classes are still there).
    static func prepareReference(_ root: Element) {
        svgObjects(root)
        mediaWiki(root)
        mdn(root)
        sphinx(root)
        latexML(root)
        arxivAbstract(root)
        for note in DOM.select(root, "annotation, annotation-xml") { DOM.remove(note) }
    }

    /// An `<object>` that holds an SVG file (arXiv's HTML figures) is a picture: Readability keeps no `<object>`.
    private static func svgObjects(_ root: Element) {
        for object in DOM.select(root, "object[data]") where DOM.isConnected(object) {
            guard let data = DOM.attr(object, "data"),
                  DOM.attr(object, "type")?.lowercased() == "image/svg+xml" || data.lowercased().hasSuffix(".svg") else { continue }
            DOM.replace(object, withHTML: "<img src=\"\(DOM.escapeAttr(data))\" alt=\"\(DOM.escapeAttr(DOM.text(object)))\">")
        }
    }

    // MARK: MediaWiki (Wikipedia)

    private static let wikiChrome = [
        ".mw-editsection", ".mw-empty-elt", ".infobox", ".navbox", ".navbox-styles", ".vertical-navbox", "table.sidebar", ".sistersitebox",
        ".ambox", ".side-box", ".mw-references-wrap", ".reflist", "ol.references", ".refbegin", "sup.reference", ".Inline-Template",
        ".mw-cite-backlink", ".printfooter", "#catlinks", ".authority-control", ".mw-authority-control",
    ].joined(separator: ", ")
    private static let wikiEndSection = P("^(?:notes?|explanatory notes|footnotes|references|citations|cited (?:references|sources|works)|sources|bibliography|works cited|further reading|external links|general references|notes and references|references and notes)$", caseInsensitive: true)
    /// "See also" stays when it is a short list; a long one is a link farm.
    static let maxSeeAlso = 12

    /// A MediaWiki article reads as its prose. The infobox (its facts are in the first sentence), maintenance banners,
    /// navboxes, citation markers and lists, and the sections that end an article (Notes, References, Further reading,
    /// External links) go, and so does the edit link beside each heading: Readability removes a short heading whose
    /// text is mostly such a link (its "heading density" rule), which lost "History" and "Libraries" from Python's page,
    /// and an empty `<tbody>` before a table's `<caption>` pushes the caption out as bare text.
    static func mediaWiki(_ root: Element) {
        guard DOM.first(root, "meta[name=generator][content^=MediaWiki], #mw-content-text, .mw-parser-output") != nil else { return }
        for el in DOM.select(root, wikiChrome) where DOM.isConnected(el) { DOM.remove(el) }
        for h in DOM.select(root, "h2") where DOM.isConnected(h) {
            let name = DOM.text(h)
            let seeAlso = name.lowercased() == "see also"
            guard seeAlso || wikiEndSection.test(name) else { continue }
            let nodes = sectionNodes(of: h)
            if seeAlso, nodes.reduce(0, { $0 + DOM.select($1, "li").count }) <= maxSeeAlso { continue }
            for node in nodes { DOM.remove(node) }
        }
    }

    /// The heading's section: the `<section>` that starts with it (Parsoid), else the heading and what follows it up to
    /// the next heading of its level or higher.
    private static func sectionNodes(of h: Element) -> [Element] {
        var unit = h
        if let parent = h.parent(), DOM.classTokens(parent).contains("mw-heading") { unit = parent }
        if let section = unit.parent(), DOM.tag(section) == "section", DOM.children(section).first === unit { return [section] }
        var nodes = [unit]
        var next = try? unit.nextElementSibling()
        while let n = next, !startsSection(n) {
            nodes.append(n)
            next = try? n.nextElementSibling()
        }
        return nodes
    }

    private static func startsSection(_ el: Element) -> Bool {
        if DOM.tag(el) == "section" || DOM.isTag(el, ["h1", "h2"]) { return true }
        return DOM.classTokens(el).contains("mw-heading") && DOM.first(el, "h1, h2") != nil
    }

    // MARK: MDN

    private static let noteWord = P("^(?:note|warning|callout|important|tip|caution)\\s*:?$", caseInsensitive: true)

    /// MDN puts the page's summary paragraph in the header box with the title, a sibling of the page body, so the
    /// extraction starts at the first section ("Try it") without saying what the page is about: it moves into the body.
    /// The baseline badge, the language label above each code block and the browser-compatibility table (a script
    /// fills it; the page holds only "Enable JavaScript") go, and `notecard` boxes become labelled quotes.
    static func mdn(_ root: Element) {
        guard let header = DOM.first(root, ".reference-layout__header, .layout__header"), DOM.first(header, "h1") != nil,
              let body = DOM.first(root, ".reference-layout__body, .layout__body") else { return }
        for intro in DOM.select(header, "section.content-section").reversed() { _ = try? body.prependChild(intro) }
        for el in DOM.select(root, "details.baseline-indicator, .example-header") { DOM.remove(el) }
        for table in DOM.select(root, "mdn-compat-table-lazy") where DOM.isConnected(table) {
            DOM.remove(DOM.closest(table, "section") ?? table)
        }
        for box in DOM.select(root, "div.notecard") where DOM.isConnected(box) {
            guard let first = DOM.children(box).first, DOM.tag(first) == "p", let lead = DOM.children(first).first,
                  DOM.isTag(lead, ["strong", "b"]), noteWord.test(DOM.text(lead)) else { continue }
            let label = DOM.text(lead).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            DOM.remove(lead)
            if DOM.text(first).isEmpty { DOM.remove(first) }
            asLabelledQuote(box, label: label)
        }
    }

    /// A box with a label becomes a blockquote whose first line is the label, which `styleCallouts` draws as a card
    /// once Readability has dropped the classes.
    private static func asLabelledQuote(_ box: Element, label: String) {
        _ = try? box.tagName("blockquote")
        _ = try? box.prepend("<p>\(DOM.escapeHTML(label))</p>")
    }

    // MARK: Sphinx (docs.python.org and most Python docs)

    /// Sphinx's permalink pilcrows (`a.headerlink`) and "[source]" links go. A signature (`dt.sig`) is the landmark of
    /// its entry, so it becomes a heading over its description instead of a small muted term. An admonition's title
    /// becomes the label line of a quote, and "Added in version 3.9." is set in italics.
    static func sphinx(_ root: Element) {
        for a in DOM.select(root, "a.headerlink") { DOM.remove(a) }
        for el in DOM.select(root, "dt.sig span.viewcode-link") { DOM.remove(el.parent().flatMap { DOM.isTag($0, ["a"]) ? $0 : nil } ?? el) }
        for box in DOM.select(root, "div.admonition, div.seealso") where DOM.isConnected(box) {
            guard let title = DOM.children(box).first, DOM.tag(title) == "p", DOM.classTokens(title).contains("admonition-title") else { continue }
            _ = try? box.tagName("blockquote")
        }
        for el in DOM.select(root, "span.versionmodified") { _ = try? el.tagName("em") }
        // Innermost first, while the enclosing dd's still tell how deep an entry is.
        var lists: [Element] = []
        for dt in DOM.select(root, "dt.sig") {
            if let dl = dt.parent(), DOM.tag(dl) == "dl", !lists.contains(where: { $0 === dl }) { lists.append(dl) }
        }
        for dl in lists.reversed() {
            var depth = 0
            var up = dl.parent()
            while let cur = up { if DOM.tag(cur) == "dd" { depth += 1 }; up = cur.parent() }
            let level = "h\(min(3 + depth, 5))"
            for child in DOM.children(dl) {
                if DOM.tag(child) == "dt", DOM.classTokens(child).contains("sig") { _ = try? child.tagName(level) }
                else if DOM.tag(child) == "dd" { _ = try? child.tagName("div") }
            }
            _ = try? dl.tagName("div")
        }
    }

    // MARK: LaTeXML (arXiv's HTML papers)

    private static let equationTable = "table.ltx_equation, table.ltx_equationgroup"

    /// A paper LaTeXML typeset keeps its math as MathML (which WebKit draws; the sanitizer lets it through) with the
    /// LaTeX source in an annotation (dropped), so the text shows once. The author block (the reader draws the byline) and
    /// the list-item tags (`•` beside the bullet the list draws) go. An equation set in a table of cells and an equation
    /// number becomes one block of math per row. A footnote, which LaTeXML writes inline in the sentence, becomes a
    /// superscript number with its text in a small paragraph under the paragraph it is in (a list at the end would be a sibling of
    /// the article Readability picks, and dropped).
    static func latexML(_ root: Element) {
        guard DOM.first(root, "meta[name=generator][content*=LaTeXML], .ltx_page_main, article.ltx_document") != nil else { return }
        for el in DOM.select(root, ".ltx_authors, .ltx_pagination, .ltx_page_footer, nav.ltx_TOC, .ltx_tag_item, .ltx_tag_itemize") { DOM.remove(el) }
        for table in DOM.select(root, equationTable) where DOM.isConnected(table) {
            if let parent = table.parent(), DOM.closest(parent, equationTable) != nil { continue }
            var html = ""
            for row in DOM.select(table, "tr") {
                let maths = DOM.select(row, "td math").filter { DOM.closest($0, "td.ltx_eqn_eqno") == nil }
                if maths.isEmpty {
                    let text = DOM.text(row)
                    if !text.isEmpty { html += "<p>\(DOM.escapeHTML(text))</p>" }
                } else {
                    html += "<p><math display=\"block\">\(maths.map { DOM.innerHTML($0) }.joined())</math></p>"
                }
            }
            DOM.replace(table, withHTML: html)
        }
        var count = 0
        for note in DOM.select(root, "span.ltx_note") where DOM.isConnected(note) {
            guard let content = DOM.first(note, ".ltx_note_content") else { continue }
            for junk in DOM.select(content, ".ltx_note_mark, .ltx_tag_note") { DOM.remove(junk) }
            count += 1
            let text = DOM.innerHTML(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if let paragraph = DOM.closest(note, "p") { _ = try? paragraph.after("<p><small><sup>\(count)</sup> \(text)</small></p>") }
            DOM.replace(note, withHTML: "<sup>\(count)</sup>")
        }
    }

    // MARK: arXiv abstract pages

    /// An arXiv abstract page is its abstract: the page's metadata table, PDF/HTML links, submission history and the
    /// title and authors (the reader's header draws them) go; the subjects stay as a line under the abstract.
    static func arxivAbstract(_ root: Element) {
        guard let abstract = DOM.first(root, "#abs blockquote.abstract") else { return }
        for label in DOM.select(abstract, ".descriptor") { DOM.remove(label) }
        let subjects = DOM.first(root, "#abs td.subjects").map { DOM.text($0) } ?? ""
        for el in DOM.select(root, "#abs .metatable, #abs .dateline, #abs h1.title, #abs .authors, #abs .mobile-submission-download, #abs #download-button-info, .submission-history, #submission-history, .extra-services, .full-text") {
            DOM.remove(el)
        }
        _ = try? abstract.tagName("p")
        if !subjects.isEmpty { _ = try? abstract.after("<p><small>Subjects: \(DOM.escapeHTML(subjects))</small></p>") }
    }

    /// The abstract page for a link straight to a paper's PDF (arxiv.org/pdf/<id>, a file the reader can't read).
    static func arxivAbstractURL(forPDF url: String) -> String? {
        guard let m = arxivPDF.firstMatch(url), let id = m[1] else { return nil }
        return "https://arxiv.org/abs/\(id)"
    }

    private static let arxivPDF = P("^https?://(?:www\\.)?arxiv\\.org/pdf/([a-z\\-]+(?:\\.[a-z]+)?/\\d{7}(?:v\\d+)?|\\d{4}\\.\\d{4,5}(?:v\\d+)?)(?:\\.pdf)?/?(?:[?#].*)?$", caseInsensitive: true)

    // MARK: README badges (after Readability)

    private static let badgeSource = P("shields\\.io|badgen\\.net|badge\\.fury\\.io|/badges?(?:/|\\.svg)|[/_-]badge\\.svg|/workflows/[^/]+/badge", caseInsensitive: true)

    /// Badges (build status, version, chat) sit side by side in a README; as pictures they would each take a line.
    /// GitHub serves them through its image proxy, so the original address is in `data-canonical-src`. The reader sets
    /// `.x-badge` inline.
    static func markBadges(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            if isBadge(img) || badgeSource.test(DOM.attr(img, "data-canonical-src") ?? "") { DOM.setAttr(img, "class", "x-badge") }
        }
    }
}
