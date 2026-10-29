import Foundation
import SwiftSoup

/// The text of a comment or post as paragraphs of styled runs, which the app draws as attributed text. Built from a
/// place's HTML (Reddit, Hacker News, X) or plain text (Bluesky, YouTube), with bare web addresses made links.
public struct RichText: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public var text: String
        public var link: String?
        public var bold = false
        public var italic = false
        public var code = false

        public init(text: String, link: String? = nil, bold: Bool = false, italic: Bool = false, code: Bool = false) {
            self.text = text
            self.link = link
            self.bold = bold
            self.italic = italic
            self.code = code
        }

        fileprivate func sameStyle(as other: Run) -> Bool {
            link == other.link && bold == other.bold && italic == other.italic && code == other.code
        }
    }

    public struct Paragraph: Sendable, Hashable {
        public enum Style: Sendable, Hashable { case plain, quote, code, bullet }
        public var runs: [Run]
        public var style: Style

        public init(runs: [Run], style: Style = .plain) {
            self.runs = runs
            self.style = style
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs
    }

    public var isEmpty: Bool { paragraphs.isEmpty }

    /// The text with paragraphs separated by blank lines.
    public var plainText: String { paragraphs.map(\.text).joined(separator: "\n\n") }

    // MARK: Plain text

    private static let bareURL = ExtractionDOM.Pattern(#"https?://[^\s<>"]+"#)

    /// Plain text: paragraphs at blank lines, line breaks kept, bare web addresses linked (trailing punctuation left out).
    public static func plain(_ text: String) -> RichText {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return RichText(paragraphs: blocks.map { Paragraph(runs: linkified($0)) })
    }

    static func linkified(_ text: String) -> [Run] {
        let ns = text as NSString
        var runs: [Run] = []
        var last = 0
        for m in bareURL.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { runs.append(Run(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            var url = ns.substring(with: m.range)
            var tail = ""
            while let c = url.last, ".,;:!?)]}\u{2019}\"'".contains(c) { tail.insert(c, at: tail.startIndex); url.removeLast() }
            runs.append(Run(text: url, link: url))
            if !tail.isEmpty { runs.append(Run(text: tail)) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { runs.append(Run(text: ns.substring(from: last))) }
        return runs
    }

    // MARK: HTML

    /// A fragment of a place's HTML: paragraphs and line breaks, quotes, code blocks, list items, links (made absolute
    /// against `base`), bold, italic and inline code. Images count only by their alt text when it is short (emoji).
    public static func html(_ html: String, base: String? = nil) -> RichText {
        var builder = Builder(base: base.flatMap(URL.init(string:)))
        _ = ExtractionDOM.withFragment(html) { body in builder.walk(body, Inline()) }
        return builder.finish()
    }

    /// An element of a parsed page.
    static func element(_ el: Element, base: String? = nil) -> RichText {
        var builder = Builder(base: base.flatMap(URL.init(string:)))
        builder.walk(el, Inline())
        return builder.finish()
    }

    private struct Inline {
        var link: String?
        var bold = false
        var italic = false
        var code = false
        var pre = false
    }

    private struct Builder {
        let base: URL?
        var paragraphs: [Paragraph] = []
        var runs: [Run] = []
        var style: Paragraph.Style = .plain

        private static let skipped: Set<String> = ["script", "style", "svg", "button", "template", "noscript", "head", "input", "select"]

        mutating func walk(_ node: Node, _ inline: Inline) {
            for child in node.getChildNodes() {
                if let t = child as? TextNode {
                    append(inline.pre ? t.getWholeText() : Self.collapse(t.getWholeText()), inline)
                } else if let el = child as? Element {
                    element(el, inline)
                }
            }
        }

        private mutating func element(_ el: Element, _ inline: Inline) {
            let tag = el.tagName().lowercased()
            if Self.skipped.contains(tag) { return }
            var inner = inline
            switch tag {
            case "br":
                append("\n", inline)
            case "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "tr":
                flush()
                if tag.hasPrefix("h") && tag.count == 2 { inner.bold = true }
                walk(el, inner)
                flush()
            case "blockquote":
                block(.quote, el, inner)
            case "pre":
                inner.pre = true
                inner.code = false
                block(.code, el, inner)
            case "li":
                block(.bullet, el, inner)
            case "a":
                if let href = try? el.attr("href"), !href.isEmpty { inner.link = absolute(href) }
                walk(el, inner)
            case "b", "strong":
                inner.bold = true
                walk(el, inner)
            case "i", "em":
                inner.italic = true
                walk(el, inner)
            case "code":
                if !inline.pre { inner.code = true }
                walk(el, inner)
            case "img":
                if let alt = try? el.attr("alt"), !alt.isEmpty, alt.count <= 4 { append(alt, inline) }
            default:
                walk(el, inner)
            }
        }

        private mutating func block(_ s: Paragraph.Style, _ el: Element, _ inline: Inline) {
            flush()
            let saved = style
            style = s
            walk(el, inline)
            flush()
            style = saved
        }

        private mutating func append(_ text: String, _ inline: Inline) {
            guard !text.isEmpty else { return }
            var text = text
            // A paragraph doesn't start with the space between two tags.
            if runs.isEmpty || runs.last?.text.hasSuffix("\n") == true, !inline.pre {
                text = String(text.drop { $0 == " " })
                guard !text.isEmpty else { return }
            }
            let run = Run(text: text, link: inline.link, bold: inline.bold, italic: inline.italic, code: inline.code)
            if let last = runs.last, last.sameStyle(as: run) {
                runs[runs.count - 1].text += text
            } else {
                runs.append(run)
            }
        }

        mutating func flush() {
            // Trailing spaces and line breaks go; so does a paragraph of only whitespace.
            while let last = runs.last {
                let trimmed = style == .code ? last.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    : last.text.replacingOccurrences(of: "[ \\n]+$", with: "", options: .regularExpression)
                if trimmed.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = trimmed; break }
            }
            if !runs.isEmpty { paragraphs.append(Paragraph(runs: runs, style: style)) }
            runs = []
        }

        mutating func finish() -> RichText {
            flush()
            return RichText(paragraphs: paragraphs)
        }

        private func absolute(_ href: String) -> String {
            guard let base, let url = URL(string: href, relativeTo: base) else { return href }
            return url.absoluteString
        }

        private static func collapse(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }
}
