import Foundation
import SwiftSoup

/// HTML to Markdown for Copy as Markdown. Handles what the article sanitizer emits (headings, paragraphs, lists,
/// quotes, code, tables, images, figures, embeds); not a general-purpose converter.
enum MarkdownConverter {
    /// Markdown for `html`. Relative links and images resolve against `baseURL`.
    static func convert(_ html: String, baseURL: String? = nil) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else {
            return TextFormat.stripHTML(html)
        }
        let renderer = Renderer(base: baseURL.flatMap { URL(string: $0) })
        return renderer.blocks(of: body, Context()).joined(separator: "\n\n")
    }

    /// Markdown for a feed summary or description: HTML as-is, plain text with its line breaks kept.
    static func convertSummary(_ text: String, baseURL: String? = nil) -> String {
        let tag = #"</?(p|br|div|span|a|b|i|u|em|strong|ul|ol|li|h[1-6]|img|blockquote|pre|code|table|hr)\b[^>]*>"#
        if text.range(of: tag, options: [.regularExpression, .caseInsensitive]) != nil { return convert(text, baseURL: baseURL) }
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
        return convert(escaped, baseURL: baseURL)
    }

    /// The text of `html` on one line, entities decoded.
    static func plainText(fromHTML html: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let text = try? doc.body()?.text() else {
            return TextFormat.stripHTML(html)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words in Markdown or plain text: whitespace-separated runs that contain a letter or digit.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { word in word.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    struct Context {
        var inStrong = false
        var inEm = false
        var inStrike = false
        var inLink = false
    }

    /// Marks a `<br>` inside an inline run; resolved into a hard break (or paragraph split) when the run is finished.
    private static let lineBreak: Character = "\u{E000}"

    private static let skipped: Set<String> = [
        "script", "style", "noscript", "svg", "template", "head", "title", "meta", "link", "textarea", "select", "option", "button", "canvas",
    ]
    private static let containers: Set<String> = [
        "div", "section", "article", "header", "footer", "main", "aside", "nav", "details", "summary", "fieldset", "form",
        "address", "center", "body", "html", "figure", "dl", "dd", "picture", "hgroup", "thead", "tbody", "tfoot", "caption",
    ]

    private final class Renderer {
        let base: URL?
        init(base: URL?) { self.base = base }

        // MARK: Blocks

        /// The block-level pieces of `parent`'s children, in order; inline runs between blocks become paragraphs.
        func blocks(of parent: Element, _ ctx: Context) -> [String] {
            var out: [String] = []
            var run = ""
            func flush() {
                out.append(contentsOf: MarkdownConverter.paragraphs(from: run))
                run = ""
            }
            for node in parent.getChildNodes() {
                if let text = node as? TextNode {
                    run += MarkdownConverter.escape(MarkdownConverter.collapse(text.getWholeText()))
                } else if let el = node as? Element {
                    let tag = el.tagName().lowercased()
                    if skipped.contains(tag) { continue }
                    if let block = block(el, tag, ctx) {
                        flush()
                        out.append(contentsOf: block)
                    } else {
                        run += inline(el, tag, ctx)
                    }
                }
            }
            flush()
            return out
        }

        /// Rendered pieces when `el` is a block element; nil when it is inline.
        private func block(_ el: Element, _ tag: String, _ ctx: Context) -> [String]? {
            switch tag {
            case "p", "li", "dt", "figcaption", "blockquote", "ul", "ol", "pre", "table", "hr", "iframe", "video",
                 "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th":
                break
            default:
                if !containers.contains(tag) { return nil }
            }
            switch tag {
            case "p", "li", "td", "th", "tr": return blocks(of: el, ctx)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(tag.dropFirst())) ?? 2
                var inner = ctx
                inner.inStrong = true
                let text = MarkdownConverter.singleLine(inline(children: el, inner))
                return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
            case "dt":
                let text = MarkdownConverter.singleLine(inline(children: el, ctx))
                return text.isEmpty ? [] : ["**" + text + "**"]
            case "figcaption":
                var inner = ctx
                inner.inEm = true
                inner.inStrong = true
                let text = MarkdownConverter.singleLine(inline(children: el, inner))
                return text.isEmpty ? [] : ["*" + text + "*"]
            case "hr": return ["---"]
            case "blockquote":
                let inner = blocks(of: el, ctx).joined(separator: "\n\n")
                if inner.isEmpty { return [] }
                return [inner.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")]
            case "ul", "ol": return list(el, ordered: tag == "ol", ctx).map { [$0] } ?? []
            case "pre": return codeBlock(el).map { [$0] } ?? []
            case "table": return table(el, ctx)
            case "iframe", "video": return embed(el, tag).map { [$0] } ?? []
            default: return blocks(of: el, ctx)
            }
        }

        // MARK: Inline

        private func inline(children el: Element, _ ctx: Context) -> String {
            var out = ""
            for node in el.getChildNodes() {
                if let text = node as? TextNode {
                    out += MarkdownConverter.escape(MarkdownConverter.collapse(text.getWholeText()))
                } else if let child = node as? Element {
                    let tag = child.tagName().lowercased()
                    if skipped.contains(tag) { continue }
                    out += inline(child, tag, ctx)
                }
            }
            return out
        }

        private func inline(_ el: Element, _ tag: String, _ ctx: Context) -> String {
            var inner = ctx
            switch tag {
            case "br": return String(MarkdownConverter.lineBreak)
            case "b", "strong":
                if ctx.inStrong { return inline(children: el, ctx) }
                inner.inStrong = true
                return wrap(inline(children: el, inner), "**")
            case "i", "em", "cite", "dfn":
                if ctx.inEm { return inline(children: el, ctx) }
                inner.inEm = true
                return wrap(inline(children: el, inner), "*")
            case "s", "del", "strike":
                if ctx.inStrike { return inline(children: el, ctx) }
                inner.inStrike = true
                return wrap(inline(children: el, inner), "~~")
            case "code", "kbd", "samp", "tt":
                let text = MarkdownConverter.collapse(MarkdownConverter.plainText(el))
                return MarkdownConverter.inlineCode(text)
            case "a": return link(el, ctx)
            case "img": return image(el)
            case "iframe", "video": return embed(el, tag) ?? ""
            case "ul", "ol", "pre", "table", "blockquote", "p", "h1", "h2", "h3", "h4", "h5", "h6", "div", "li":
                // A block nested in an inline context (e.g. inside a link): flatten to one line.
                return " " + (block(el, tag, ctx) ?? []).joined(separator: " ") + " "
            default: return inline(children: el, ctx)
            }
        }

        /// Wraps non-blank `inner` in `mark`, keeping edge spaces outside the markers.
        private func wrap(_ inner: String, _ mark: String) -> String {
            let core = inner.trimmingCharacters(in: .whitespaces)
            if core.isEmpty || core.allSatisfy({ $0 == MarkdownConverter.lineBreak }) { return inner }
            let lead = inner.prefix(while: { $0 == " " })
            let trail = inner.reversed().prefix(while: { $0 == " " })
            return String(lead) + mark + core + mark + String(trail)
        }

        private func link(_ el: Element, _ ctx: Context) -> String {
            var inner = ctx
            inner.inLink = true
            let text = inline(children: el, inner)
            guard !ctx.inLink, let href = resolve((try? el.attr("href")) ?? "", allowed: ["http", "https", "mailto"]) else { return text }
            let label = text.trimmingCharacters(in: .whitespaces)
            if label.isEmpty { return text }
            if label == MarkdownConverter.escape(href) || label == href { return "<" + href + ">" }
            let lead = text.prefix(while: { $0 == " " })
            let trail = text.reversed().prefix(while: { $0 == " " })
            return String(lead) + "[" + label + "](" + MarkdownConverter.destination(href) + ")" + String(trail)
        }

        private func image(_ el: Element) -> String {
            var src = (try? el.attr("src")) ?? ""
            if src.isEmpty, let srcset = try? el.attr("srcset"), let first = srcset.split(separator: ",").first {
                src = first.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            }
            guard let url = resolve(src, allowed: ["http", "https"]) else { return "" }
            let alt = ((try? el.attr("alt")) ?? "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            return "![" + MarkdownConverter.collapse(alt).trimmingCharacters(in: .whitespaces) + "](" + MarkdownConverter.destination(url) + ")"
        }

        /// A link for a YouTube/Vimeo iframe or a `<video>` source; nil for anything else.
        private func embed(_ el: Element, _ tag: String) -> String? {
            if tag == "video" {
                var src = (try? el.attr("src")) ?? ""
                if src.isEmpty, let source = try? el.select("source[src]").first() { src = (try? source.attr("src")) ?? "" }
                guard let url = resolve(src, allowed: ["http", "https"]) else { return nil }
                return "[Video](" + MarkdownConverter.destination(url) + ")"
            }
            guard let src = resolve((try? el.attr("src")) ?? "", allowed: ["http", "https"]), let url = URL(string: src) else { return nil }
            let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
            let parts = url.pathComponents
            if host == "youtube.com" || host == "youtube-nocookie.com", parts.count >= 3, parts[1] == "embed" {
                return "[YouTube video](https://www.youtube.com/watch?v=" + parts[2] + ")"
            }
            if host == "player.vimeo.com", parts.count >= 3, parts[1] == "video" {
                return "[Vimeo video](https://vimeo.com/" + parts[2] + ")"
            }
            return nil
        }

        /// Absolute URL for `raw` when its scheme is in `allowed`; nil for fragments, javascript:, data: and empty values.
        private func resolve(_ raw: String, allowed: Set<String>) -> String? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("#") { return nil }
            let url: URL? = base.flatMap { URL(string: s, relativeTo: $0)?.absoluteURL } ?? URL(string: s)
            guard let url, let scheme = url.scheme?.lowercased(), allowed.contains(scheme) else { return nil }
            return url.absoluteString
        }

        // MARK: Lists

        private func list(_ el: Element, ordered: Bool, _ ctx: Context) -> String? {
            var number = Int((try? el.attr("start")) ?? "") ?? 1
            var items: [String] = []
            for child in el.children().array() {
                let tag = child.tagName().lowercased()
                var pieces: [String]
                if tag == "li" {
                    pieces = blocks(of: child, ctx)
                } else if tag == "ul" || tag == "ol" {
                    // A list placed directly in a list: nest it under the previous item.
                    guard let nested = list(child, ordered: tag == "ol", ctx) else { continue }
                    if let last = items.popLast() {
                        items.append(last + "\n" + nested.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
                    } else {
                        items.append(nested)
                    }
                    continue
                } else {
                    continue
                }
                if pieces.isEmpty { continue }
                let marker = ordered ? "\(number). " : "- "
                number += 1
                let pad = String(repeating: " ", count: marker.count)
                var text = marker
                for (i, piece) in pieces.enumerated() {
                    if i > 0 {
                        let nestedList = piece.hasPrefix("- ") || piece.range(of: #"^\d+\. "#, options: .regularExpression) != nil
                        text += nestedList && !pieces[i - 1].isEmpty ? "\n" : "\n\n"
                    }
                    text += piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { j, line in
                        let l = String(line)
                        return j == 0 && i == 0 ? l : (l.isEmpty ? l : pad + l)
                    }.joined(separator: "\n")
                }
                items.append(text)
            }
            return items.isEmpty ? nil : items.joined(separator: "\n")
        }

        // MARK: Code

        private func codeBlock(_ el: Element) -> String? {
            var text = MarkdownConverter.plainText(el)
            if text.hasPrefix("\n") { text.removeFirst() }
            while text.hasSuffix("\n") { text.removeLast() }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            var language = ""
            let carriers = [el] + ((try? el.select("code").array()) ?? [])
            for carrier in carriers {
                let classes = (try? carrier.attr("class")) ?? ""
                if let m = classes.range(of: #"(?:language|lang)-([A-Za-z0-9_+#.-]+)"#, options: .regularExpression) {
                    language = String(classes[m]).replacingOccurrences(of: #"^(?:language|lang)-"#, with: "", options: .regularExpression)
                    break
                }
            }
            let fence = String(repeating: "`", count: max(3, MarkdownConverter.longestBacktickRun(text) + 1))
            return fence + language + "\n" + text + "\n" + fence
        }

        // MARK: Tables

        private func table(_ el: Element, _ ctx: Context) -> [String] {
            let rows = ((try? el.select("tr").array()) ?? []).filter { row in
                // Rows of a nested table belong to that table.
                var p = row.parent()
                while let e = p, e !== el {
                    if e.tagName().lowercased() == "table" { return false }
                    p = e.parent()
                }
                return true
            }
            let cells: [[Element]] = rows.map { row in
                row.children().array().filter { ["td", "th"].contains($0.tagName().lowercased()) }
            }.filter { !$0.isEmpty }
            if cells.isEmpty { return [] }
            if cells.count == 1, cells[0].count == 1 { return blocks(of: cells[0][0], ctx) }

            let nested = ((try? el.select("table").array()) ?? []).contains { $0 !== el }
            let spanning = cells.joined().contains { cell in
                ["colspan", "rowspan"].contains { (Int((try? cell.attr($0)) ?? "") ?? 1) > 1 }
            }
            let simple = !nested && !spanning
            let rendered: [[String]] = cells.map { row in
                row.map { cell in
                    MarkdownConverter.singleLine(blocks(of: cell, ctx).joined(separator: " "))
                }
            }
            guard simple, cells.count >= 2 else {
                return [rendered.map { "- " + $0.filter { !$0.isEmpty }.joined(separator: " | ") }.filter { $0 != "- " }.joined(separator: "\n")]
            }
            let width = rendered.map(\.count).max() ?? 1
            func line(_ row: [String]) -> String {
                let padded = row + Array(repeating: "", count: width - row.count)
                return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            var out = [line(rendered[0]), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
            out.append(contentsOf: rendered.dropFirst().map(line))
            return [out.joined(separator: "\n")]
        }
    }

    // MARK: Text helpers

    /// Browser-style whitespace: every run (including no-break spaces) becomes one space.
    static func collapse(_ s: String) -> String {
        var out = ""
        var space = false
        for ch in s {
            if ch.isWhitespace || ch == "\u{A0}" {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(ch)
                space = false
            }
        }
        return out
    }

    /// Text of an element with whitespace kept as written (`<br>` as a newline).
    private static func plainText(_ el: Element) -> String {
        var out = ""
        for node in el.getChildNodes() {
            if let text = node as? TextNode {
                out += text.getWholeText()
            } else if let child = node as? Element {
                out += child.tagName().lowercased() == "br" ? "\n" : plainText(child)
            }
        }
        return out
    }

    /// An inline run on one line: breaks become spaces, whitespace collapsed.
    private static func singleLine(_ run: String) -> String {
        collapse(run.replacingOccurrences(of: String(lineBreak), with: " ")).trimmingCharacters(in: .whitespaces)
    }

    /// Paragraphs from an inline run: `<br>` becomes a hard break, two in a row a paragraph break.
    private static func paragraphs(from run: String) -> [String] {
        var out: [String] = []
        var lines: [String] = []
        func flush() {
            if !lines.isEmpty { out.append(lines.joined(separator: "  \n")) }
            lines = []
        }
        for segment in run.split(separator: lineBreak, omittingEmptySubsequences: false) {
            let line = collapse(String(segment)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else {
                lines.append(escapeLineStart(line))
            }
        }
        flush()
        return out
    }

    /// Escapes characters that would turn into formatting inside running text.
    static func escape(_ s: String) -> String {
        guard s.contains(where: { "\\*_`<&".contains($0) }) else { return s }
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch ch {
            case "\\":
                if let n = next, n.isASCII, n.isPunctuation || n.isSymbol { out += "\\\\" } else { out.append(ch) }
            case "*", "`":
                out += "\\" + String(ch)
            case "_":
                let inWord = (prev?.isLetter == true || prev?.isNumber == true) && (next?.isLetter == true || next?.isNumber == true)
                out += inWord ? "_" : "\\_"
            case "<":
                if let n = next, n.isLetter || n == "/" || n == "!" || n == "?" { out += "\\<" } else { out.append(ch) }
            case "&":
                let rest = String(chars[(i + 1)...].prefix(10))
                if rest.range(of: #"^#?[A-Za-z0-9]+;"#, options: .regularExpression) != nil { out += "\\&" } else { out.append(ch) }
            default: out.append(ch)
            }
        }
        return out
    }

    /// Escapes a line that would start a heading, quote, list item, rule or code fence.
    static func escapeLineStart(_ line: String) -> String {
        if line.range(of: #"^(#{1,6}|>|[-+])(\s|$)"#, options: .regularExpression) != nil
            || line.range(of: #"^(>|~~~)"#, options: .regularExpression) != nil
            || line.range(of: #"^(-{2,}|={2,}|_{3,})\s*$"#, options: .regularExpression) != nil {
            return "\\" + line
        }
        if let r = line.range(of: #"^\d{1,9}(?=[.)](\s|$))"#, options: .regularExpression) {
            return line[r] + "\\" + line[r.upperBound...]
        }
        return line
    }

    private static func longestBacktickRun(_ s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            run = ch == "`" ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    private static func inlineCode(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        let fence = String(repeating: "`", count: longestBacktickRun(t) > 0 ? longestBacktickRun(t) + 1 : 1)
        let pad = t.hasPrefix("`") || t.hasSuffix("`") ? " " : ""
        return fence + pad + t + pad + fence
    }

    /// A link destination safe inside `(...)`.
    private static func destination(_ url: String) -> String {
        var out = ""
        for ch in url {
            switch ch {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "<": out += "%3C"
            case ">": out += "%3E"
            case "\n", "\r", "\t": break
            default: out.append(ch)
            }
        }
        return out
    }
}
