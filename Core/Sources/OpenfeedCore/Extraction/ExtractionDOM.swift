import Foundation
import SwiftSoup

/// DOM and text helpers shared by the extraction passes (the linkedom idioms of src/lib/extract.ts, on SwiftSoup).
/// Conventions that mirror the DOM API:
/// - `select(_:_:)` / `first(_:_:)` never return the element they are called on (querySelectorAll semantics).
/// - `closest(_:_:)` includes the element itself.
/// - `attr(_:_:)` returns nil for a missing *or empty* attribute (the JS code treats both as falsy).
enum ExtractionDOM {
    /// A compiled regular expression with the JS-style helpers the port needs. Patterns are constants.
    final class Pattern: @unchecked Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String, caseInsensitive: Bool = false) {
            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            do {
                regex = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                // Constant patterns only; a typo is a programming error caught by the tests.
                preconditionFailure("Invalid extraction pattern \(pattern): \(error)")
            }
        }

        func test(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }

        /// Capture groups of the first match (index 0 = whole match); nil groups for non-participating ones.
        func firstMatch(_ s: String, from offset: Int = 0) -> [String?]? {
            let ns = s as NSString
            guard offset <= ns.length,
                  let m = regex.firstMatch(in: s, range: NSRange(location: offset, length: ns.length - offset)) else { return nil }
            return Self.groups(m, in: ns)
        }

        /// UTF-16 location of the first match at or after `offset`, with its groups.
        func firstMatchWithRange(_ s: String, from offset: Int = 0) -> (range: NSRange, groups: [String?])? {
            let ns = s as NSString
            guard offset <= ns.length,
                  let m = regex.firstMatch(in: s, range: NSRange(location: offset, length: ns.length - offset)) else { return nil }
            return (m.range, Self.groups(m, in: ns))
        }

        func allMatches(_ s: String) -> [[String?]] {
            let ns = s as NSString
            return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Self.groups($0, in: ns) }
        }

        func replacing(_ s: String, with template: String) -> String {
            regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }

        /// Replace each match with the closure's result (groups as in firstMatch).
        func replacing(_ s: String, _ transform: ([String?]) -> String) -> String {
            let ns = s as NSString
            let found = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { return s }
            var out = ""
            var last = 0
            for m in found {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += transform(Self.groups(m, in: ns))
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            return out
        }

        private static func groups(_ m: NSTextCheckingResult, in ns: NSString) -> [String?] {
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    // MARK: Text

    private static let spaceRun = Pattern("[\\s\\u00A0]+")

    /// `squash`: whitespace (incl. NBSP) collapsed to single spaces, trimmed.
    static func squash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        return spaceRun.replacing(s, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `norm`: squash + lowercase.
    static func norm(_ s: String?) -> String { squash(s).lowercased() }

    /// `textLen`: length of the squashed text.
    static func textLen(_ s: String?) -> Int { squash(s).count }

    /// textContent: the raw text of a node and its descendants, whitespace untouched.
    static func rawText(_ node: Node?) -> String {
        guard let node else { return "" }
        if let t = node as? TextNode { return t.getWholeText() }
        if let el = node as? Element { return (try? el.text(trimAndNormaliseWhitespace: false)) ?? "" }
        return ""
    }

    /// Squashed text content of an element (SwiftSoup's normalized text).
    static func text(_ node: Node?) -> String {
        guard let node else { return "" }
        if let t = node as? TextNode { return squash(t.getWholeText()) }
        if let el = node as? Element { return squash((try? el.text()) ?? "") }
        return ""
    }

    /// `proseLen`: total text length of the <p> descendants.
    static func proseLen(_ el: Element) -> Int {
        select(el, "p").reduce(0) { $0 + textLen(text($1)) }
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttr(_ s: String) -> String {
        escapeHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()`
    private static let tagPattern = Pattern("<[^>]+>")
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        return squash(tagPattern.replacing(html, with: " "))
    }

    /// JS `Number(attr)`: missing/blank → 0, otherwise the numeric value or NaN.
    static func jsNumber(_ s: String?) -> Double {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        return Double(t) ?? .nan
    }

    private static let leadingFloat = Pattern("^\\s*[+-]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?")

    /// JS `Number.parseFloat`: the leading number, or nil (NaN).
    static func jsParseFloat(_ s: String?) -> Double? {
        guard let s, let m = leadingFloat.firstMatch(s), let whole = m[0] else { return nil }
        return Double(whole.trimmingCharacters(in: .whitespaces))
    }

    /// JS `encodeURIComponent`.
    static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: URLs

    /// `abs(u, base)`: resolve `u` against `base` (like `new URL(u, base).toString()`), nil when blank or unparseable.
    static func absURL(_ u: String?, base: String) -> String? {
        guard let raw = u?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\r", with: "")
        if let direct = URL(string: cleaned), let scheme = direct.scheme, !scheme.isEmpty {
            return direct.absoluteString
        }
        guard let baseURL = URL(string: base), let resolved = URL(string: cleaned, relativeTo: baseURL) else { return nil }
        return resolved.absoluteURL.absoluteString
    }

    /// Hostname of an absolute URL, or nil.
    static func hostname(_ u: String) -> String? {
        guard let url = URL(string: u), let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host
    }

    // MARK: Parsing and serializing

    static func configure(_ doc: Document) {
        doc.outputSettings().prettyPrint(pretty: false)
    }

    /// A full document (page HTML).
    static func parseDocument(_ html: String, baseURI: String = "") -> Document? {
        guard let doc = try? SwiftSoup.parse(html, baseURI) else { return nil }
        configure(doc)
        return doc
    }

    /// Parse a fragment into a fresh document and run `work` on its body while the document is alive.
    /// (SwiftSoup parents are weak references: a body whose Document has been released has no parent, which breaks
    /// isConnected/closest. Never let a fragment's elements escape `work` unless the caller keeps them attached.)
    static func withFragment<T>(_ html: String, _ work: (Element) throws -> T) rethrows -> T? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else { return nil }
        configure(doc)
        return try withExtendedLifetime(doc) { try work(body) }
    }

    static func outerHTML(_ el: Element) -> String { (try? el.outerHtml()) ?? "" }
    static func innerHTML(_ el: Element) -> String { (try? el.html()) ?? "" }

    static func createElement(_ name: String, near node: Node) -> Element? {
        if let doc = node.ownerDocument(), let el = try? doc.createElement(name) { return el }
        guard let tag = try? Tag.valueOf(name) else { return nil }
        return Element(tag, "")
    }

    // MARK: Queries

    /// querySelectorAll: matches below `root` in document order, excluding `root` itself.
    static func select(_ root: Element, _ query: String) -> [Element] {
        guard let found = try? root.select(query) else { return [] }
        return found.array().filter { $0 !== root }
    }

    /// querySelector.
    static func first(_ root: Element, _ query: String) -> Element? {
        select(root, query).first
    }

    static func matches(_ el: Element, _ query: String) -> Bool {
        (try? el.iS(query)) ?? false
    }

    /// Element.closest (includes the element itself).
    static func closest(_ el: Element, _ query: String) -> Element? {
        var cur: Element? = el
        while let c = cur {
            if c is Document { return nil }
            if matches(c, query) { return c }
            cur = c.parent()
        }
        return nil
    }

    /// Lowercased tag name.
    static func tag(_ el: Element) -> String { el.tagNameNormal() }

    static func isTag(_ el: Element, _ names: Set<String>) -> Bool { names.contains(tag(el)) }

    static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// getAttribute, with "" treated as missing.
    static func attr(_ el: Element, _ name: String) -> String? {
        guard el.hasAttr(name), let v = try? el.attr(name), !v.isEmpty else { return nil }
        return v
    }

    static func setAttr(_ el: Element, _ name: String, _ value: String) {
        _ = try? el.attr(name, value)
    }

    static func removeAttr(_ el: Element, _ name: String) {
        _ = try? el.removeAttr(name)
    }

    static func classTokens(_ el: Element) -> [String] {
        (attr(el, "class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Element children (no text nodes).
    static func children(_ el: Element) -> [Element] { el.children().array() }

    /// True when `node` is still attached to a document (DOM isConnected).
    static func isConnected(_ node: Node) -> Bool {
        var cur: Node = node
        while let p = cur.parent() { cur = p }
        return cur is Document
    }

    /// `a.contains(b)`: b is a or a descendant of a.
    static func contains(_ a: Node, _ b: Node) -> Bool {
        var cur: Node? = b
        while let c = cur {
            if c === a { return true }
            cur = c.parent()
        }
        return false
    }

    static func remove(_ node: Node) {
        guard node.parent() != nil else { return }
        try? node.remove()
    }

    static func replace(_ old: Node, with new: Node) {
        guard old.parent() != nil else { return }
        try? old.replaceWith(new)
    }

    /// Replace `old` with parsed HTML.
    static func replace(_ old: Element, withHTML html: String) {
        guard old.parent() != nil else { return }
        if !html.isEmpty { _ = try? old.before(html) }
        try? old.remove()
    }

    /// Position of every element under `root` in document order (for `at(el)` comparisons).
    static func documentOrder(_ root: Element) -> [ObjectIdentifier: Int] {
        var map: [ObjectIdentifier: Int] = [:]
        guard let all = try? root.select("*") else { return map }
        for (i, el) in all.array().enumerated() { map[ObjectIdentifier(el)] = i }
        return map
    }

    /// Number of elements below `el` (querySelectorAll("*").length).
    static func descendantCount(_ el: Element) -> Int {
        select(el, "*").count
    }
}
