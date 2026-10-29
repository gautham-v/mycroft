import Foundation

/// developer.apple.com/documentation pages are a script-drawn app (the HTML says "This page requires JavaScript") and
/// extract to nothing. The site serves each page's content as DocC JSON at /tutorials/data/documentation/<path>.json:
/// the reader shows it as the page reads, top to bottom: what the thing is (kind, framework, platforms), the abstract,
/// the declaration as code, parameters, the overview sections, then the topics and See Also as lists of links.
/// References (`doc://` identifiers) are resolved through the JSON's own `references`; the long conformance lists of
/// a protocol (every type that is a View) are left out.
enum AppleDocumentation {
    private typealias DOM = ExtractionDOM
    private typealias P = ExtractionDOM.Pattern

    static let origin = "https://developer.apple.com"
    private static let pageURL = P("^https?://developer\\.apple\\.com/documentation/([^?#]+?)/?(?:[?#].*)?$", caseInsensitive: true)
    /// A relationships list longer than this (View's conforming types) is noise.
    static let maxRelationships = 15

    /// The JSON address for a documentation page, or nil for any other address.
    static func apiURL(_ url: String) -> String? {
        guard let m = pageURL.firstMatch(url), let path = m[1] else { return nil }
        return "\(origin)/tutorials/data/documentation/\(path.lowercased()).json"
    }

    /// The page from the JSON, or nil when it isn't a symbol or article page.
    static func render(_ data: Data, pageURL: String) -> ExtractResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["kind"] as? String, kind == "symbol" || kind == "article" else { return nil }
        let r = Renderer(references: json["references"] as? [String: Any] ?? [:])
        var html = ""
        let meta = json["metadata"] as? [String: Any] ?? [:]
        let facts = ([meta["roleHeading"] as? String] + [((meta["modules"] as? [[String: Any]])?.first?["name"] as? String)]
            + ((meta["platforms"] as? [[String: Any]]) ?? []).prefix(8).map { p -> String? in
                guard let name = p["name"] as? String else { return nil }
                return (p["introducedAt"] as? String).map { "\(name) \($0)+" } ?? name
            }).compactMap { $0 }.filter { !$0.isEmpty }
        let abstract = r.inline(json["abstract"])
        if !abstract.isEmpty { html += "<p>\(abstract)</p>" }
        if !facts.isEmpty { html += "<p><small>\(DOM.escapeHTML(facts.joined(separator: " · ")))</small></p>" }
        for section in (json["primaryContentSections"] as? [[String: Any]]) ?? [] {
            switch section["kind"] as? String {
            case "declarations": html += declarations(section)
            case "parameters": html += r.parameters(section)
            case "content": html += r.blocks(section["content"])
            default: break
            }
        }
        html += r.relationships(json["relationshipsSections"])
        html += r.topics(json["topicSections"], heading: "Topics")
        html += r.topics(json["seeAlsoSections"], heading: "See Also")
        guard DOM.plainText(html).count > 0 else { return nil }
        let styled = DOM.withFragment(html) { body -> String in
            ArticlePasses.styleCallouts(body)
            return DOM.innerHTML(body)
        } ?? html
        return ExtractResult(contentHtml: ArticleSanitizer.sanitize(styled), leadImage: nil)
    }

    /// The declaration as code: the Swift one when there is one, each distinct text once.
    private static func declarations(_ section: [String: Any]) -> String {
        let all = (section["declarations"] as? [[String: Any]]) ?? []
        let swift = all.filter { (($0["languages"] as? [String]) ?? []).contains("swift") }
        var seen = Set<String>()
        return (swift.isEmpty ? all : swift).prefix(3).compactMap { d -> String? in
            let text = ((d["tokens"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return "<pre><code>\(DOM.escapeHTML(text))</code></pre>"
        }.joined()
    }

    /// DocC content → HTML; `references` resolves identifiers to titles, addresses and pictures.
    private struct Renderer {
        let references: [String: Any]

        private func ref(_ id: String?) -> [String: Any]? { id.flatMap { references[$0] as? [String: Any] } }
        private func esc(_ any: Any?) -> String { DOM.escapeHTML((any as? String) ?? "") }

        private func absolute(_ url: String) -> String {
            url.hasPrefix("/") ? origin + url : url
        }

        // MARK: Inline

        func inline(_ items: Any?) -> String {
            ((items as? [[String: Any]]) ?? []).map(inlineItem).joined()
        }

        private func inlineItem(_ i: [String: Any]) -> String {
            switch i["type"] as? String {
            case "text": return esc(i["text"])
            case "codeVoice": return "<code>\(esc(i["code"]))</code>"
            case "emphasis", "newTerm": return "<em>\(inline(i["inlineContent"]))</em>"
            case "strong", "inlineHead": return "<strong>\(inline(i["inlineContent"]))</strong>"
            case "superscript": return "<sup>\(inline(i["inlineContent"]))</sup>"
            case "subscript": return "<sub>\(inline(i["inlineContent"]))</sub>"
            case "strikethrough": return "<s>\(inline(i["inlineContent"]))</s>"
            case "image": return picture(i["identifier"] as? String) ?? ""
            case "reference": return reference(i)
            case "link":
                let title = (i["title"] as? String) ?? (i["destination"] as? String) ?? ""
                guard let dest = i["destination"] as? String else { return DOM.escapeHTML(title) }
                return "<a href=\"\(DOM.escapeAttr(dest))\">\(DOM.escapeHTML(title))</a>"
            default: return inline(i["inlineContent"])
            }
        }

        /// A symbol reference reads as code, as on the page; one without a page is its name.
        private func reference(_ i: [String: Any]) -> String {
            let id = i["identifier"] as? String
            let target = ref(id)
            var title = inline(i["overridingTitleInlineContent"])
            if title.isEmpty, let t = i["overridingTitle"] as? String { title = DOM.escapeHTML(t) }
            if title.isEmpty { title = titleHTML(target) }
            if title.isEmpty, let last = id?.split(separator: "/").last { title = DOM.escapeHTML(String(last)) }
            let isSymbol = (target?["role"] as? String) == "symbol" && i["overridingTitleInlineContent"] == nil
            if isSymbol { title = "<code>\(title)</code>" }
            guard (i["isActive"] as? Bool) != false, let url = target?["url"] as? String else { return title }
            return "<a href=\"\(DOM.escapeAttr(absolute(url)))\">\(title)</a>"
        }

        private func titleHTML(_ target: [String: Any]?) -> String {
            guard let target else { return "" }
            let rich = inline(target["titleInlineContent"])
            return rich.isEmpty ? esc(target["title"]) : rich
        }

        /// The light-mode picture of an image reference, as an <img>.
        private func picture(_ id: String?) -> String? {
            guard let image = ref(id), let variants = image["variants"] as? [[String: Any]], !variants.isEmpty else { return nil }
            func traits(_ v: [String: Any]) -> [String] { (v["traits"] as? [String]) ?? [] }
            let light = variants.filter { !traits($0).contains("dark") }
            let best = (light.first { traits($0).contains("2x") } ?? light.first ?? variants.first)
            guard let url = best?["url"] as? String else { return nil }
            return "<img src=\"\(DOM.escapeAttr(absolute(url)))\" alt=\"\(DOM.escapeAttr((image["alt"] as? String) ?? ""))\">"
        }

        // MARK: Blocks

        func blocks(_ items: Any?) -> String {
            ((items as? [[String: Any]]) ?? []).map(block).joined()
        }

        private func block(_ b: [String: Any]) -> String {
            switch b["type"] as? String {
            case "paragraph":
                let inner = inline(b["inlineContent"])
                return inner.isEmpty ? "" : "<p>\(inner)</p>"
            case "heading":
                let level = min(max((b["level"] as? Int) ?? 2, 2), 4)
                return "<h\(level)>\(esc(b["text"]))</h\(level)>"
            case "codeListing":
                let code = ((b["code"] as? [String]) ?? []).joined(separator: "\n")
                let language = (b["syntax"] as? String).map { " class=\"language-\(DOM.escapeAttr($0))\"" } ?? ""
                return "<pre><code\(language)>\(DOM.escapeHTML(code))</code></pre>"
            case "unorderedList", "orderedList":
                let tag = (b["type"] as? String) == "orderedList" ? "ol" : "ul"
                let items = ((b["items"] as? [[String: Any]]) ?? []).map { "<li>\(listItem($0["content"]))</li>" }.joined()
                return "<\(tag)>\(items)</\(tag)>"
            case "aside":
                let label = (b["name"] as? String) ?? ((b["style"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Note")
                return "<blockquote><p>\(DOM.escapeHTML(label))</p>\(blocks(b["content"]))</blockquote>"
            case "table":
                return table(b)
            case "termList":
                let items = ((b["items"] as? [[String: Any]]) ?? []).map { item -> String in
                    let term = inline((item["term"] as? [String: Any])?["inlineContent"])
                    return "<dt>\(term)</dt><dd>\(blocks((item["definition"] as? [String: Any])?["content"]))</dd>"
                }.joined()
                return "<dl>\(items)</dl>"
            case "links":
                let items = ((b["items"] as? [String]) ?? []).compactMap { link($0) }.map { "<li>\($0)</li>" }.joined()
                return items.isEmpty ? "" : "<ul>\(items)</ul>"
            case "image":
                return picture(b["identifier"] as? String).map { "<figure>\($0)</figure>" } ?? ""
            case "small":
                return "<p><small>\(inline(b["inlineContent"]))</small></p>"
            case "thematicBreak":
                return "<hr>"
            case "row":
                return ((b["columns"] as? [[String: Any]]) ?? []).map { blocks($0["content"]) }.joined()
            case "tabNavigator":
                return ((b["tabs"] as? [[String: Any]]) ?? []).map { "<h4>\(esc($0["title"]))</h4>\(blocks($0["content"]))" }.joined()
            case "step":
                return blocks(b["content"]) + blocks(b["caption"])
            default:
                if b["content"] != nil { return blocks(b["content"]) }
                return b["inlineContent"] != nil ? "<p>\(inline(b["inlineContent"]))</p>" : ""
            }
        }

        /// A list item of a single paragraph is just its text.
        private func listItem(_ content: Any?) -> String {
            let items = (content as? [[String: Any]]) ?? []
            if items.count == 1, (items[0]["type"] as? String) == "paragraph" { return inline(items[0]["inlineContent"]) }
            return blocks(items)
        }

        private func table(_ b: [String: Any]) -> String {
            let rows = (b["rows"] as? [[Any]]) ?? []
            let head = (b["header"] as? String) ?? "none"
            let html = rows.enumerated().map { index, row -> String in
                let isHead = head == "row" && index == 0
                let cells = row.map { cell -> String in
                    let inner = blocks(cell as? [[String: Any]] ?? [])
                    return isHead ? "<th>\(inner)</th>" : "<td>\(inner)</td>"
                }.joined()
                return "<tr>\(cells)</tr>"
            }.joined()
            return html.isEmpty ? "" : "<table><tbody>\(html)</tbody></table>"
        }

        // MARK: Page sections

        func parameters(_ section: [String: Any]) -> String {
            let items = ((section["parameters"] as? [[String: Any]]) ?? []).map {
                "<dt><code>\(esc($0["name"]))</code></dt><dd>\(blocks($0["content"]))</dd>"
            }.joined()
            return items.isEmpty ? "" : "<h2>Parameters</h2><dl>\(items)</dl>"
        }

        /// One topic or related page: its title as a link (code for a symbol), then its abstract.
        private func link(_ id: String) -> String? {
            guard let target = ref(id), let url = target["url"] as? String else { return nil }
            var title = titleHTML(target)
            if title.isEmpty { return nil }
            if (target["role"] as? String) == "symbol" { title = "<code>\(title)</code>" }
            let abstract = inline(target["abstract"])
            return "<a href=\"\(DOM.escapeAttr(absolute(url)))\">\(title)</a>" + (abstract.isEmpty ? "" : "<br>\(abstract)")
        }

        private func sections(_ any: Any?) -> String {
            ((any as? [[String: Any]]) ?? []).map { section -> String in
                let items = ((section["identifiers"] as? [String]) ?? []).compactMap { link($0) }.map { "<li>\($0)</li>" }.joined()
                guard !items.isEmpty else { return "" }
                let title = (section["title"] as? String).map { "<h3>\(DOM.escapeHTML($0))</h3>" } ?? ""
                return "\(title)<ul>\(items)</ul>"
            }.joined()
        }

        func topics(_ any: Any?, heading: String) -> String {
            let body = sections(any)
            return body.isEmpty ? "" : "<h2>\(heading)</h2>\(body)"
        }

        func relationships(_ any: Any?) -> String {
            let short = ((any as? [[String: Any]]) ?? []).filter { (($0["identifiers"] as? [String]) ?? []).count <= AppleDocumentation.maxRelationships }
            let body = sections(short)
            return body.isEmpty ? "" : "<h2>Relationships</h2>\(body)"
        }
    }
}
