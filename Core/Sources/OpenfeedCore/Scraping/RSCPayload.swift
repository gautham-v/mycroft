import Foundation

/// Next.js App Router pages carry their React Server Components payload in the HTML as
/// `self.__next_f.push([1,"..."])` scripts. Client-rendered parts of a page (charts, video players)
/// are empty in the server HTML, but their props, data included, are in this payload.
/// Port of src/lib/rsc.ts.
///
/// The payload is scanned as UTF-8 bytes (`[UInt8]`, from `bytes(_:)`); every offset in this API is a
/// byte offset into that array. JSON values are Foundation's (`[String: Any]`, `[Any]`, `String`,
/// `NSNumber`, `NSNull`), as `JSONSerialization` returns them.
public enum RSCPayload {
    private static let push = ScrapingText.regex(#"self\.__next_f\.push\(\[\s*1\s*,\s*("(?:[^"\\]|\\.)*")\s*\]\)"#)
    /// How far back from a marker its enclosing object may start, and how many `{` to try.
    private static let maxLookback = 2_000_000
    private static let maxTries = 20_000

    /// The RSC stream: every pushed string chunk, decoded and joined in order (a row can span pushes).
    public static func payload(_ html: String) -> String {
        guard html.contains("__next_f") else { return "" }
        var out = ""
        for literal in ScrapingText.allGroups(push, html, group: 1) {
            guard let data = literal.data(using: .utf8),
                  let s = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
            else { continue }  // not a JSON string literal; skip the chunk
            out += s
        }
        return out
    }

    public static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Byte offsets of every occurrence of `needle` in `text`.
    public static func offsets(of needle: String, in text: [UInt8]) -> [Int] {
        let n = Array(needle.utf8)
        guard let first = n.first, n.count <= text.count else { return [] }
        var out: [Int] = []
        var i = 0
        let limit = text.count - n.count
        while i <= limit {
            if text[i] == first, matches(text, at: i, n) {
                out.append(i)
                i += n.count
            } else {
                i += 1
            }
        }
        return out
    }

    private static func matches(_ text: [UInt8], at i: Int, _ n: [UInt8]) -> Bool {
        guard i >= 0, i + n.count <= text.count else { return false }
        for j in 0..<n.count where text[i + j] != n[j] { return false }
        return true
    }

    private static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")

    /// Index just past the JSON object/array that opens at `start`, or -1 if it never closes.
    public static func balancedEnd(_ text: [UInt8], _ start: Int) -> Int {
        guard start >= 0, start < text.count, text[start] == openBrace || text[start] == openBracket else { return -1 }
        var depth = 0
        var inString = false
        var i = start
        while i < text.count {
            let c = text[i]
            if inString {
                if c == backslash { i += 1 } else if c == quote { inString = false }
            } else if c == quote {
                inString = true
            } else if c == openBrace || c == openBracket {
                depth += 1
            } else if c == closeBrace || c == closeBracket {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return -1
    }

    static func parseJSON(_ text: [UInt8], _ range: Range<Int>) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text[range]), options: [.fragmentsAllowed])
    }

    private static func lastIndex(of byte: UInt8, in text: [UInt8], atOrBefore pos: Int) -> Int? {
        var i = min(pos, text.count - 1)
        while i >= 0 {
            if text[i] == byte { return i }
            i -= 1
        }
        return nil
    }

    /// The innermost JSON object around `pos` that parses and passes `accept`, with where it starts.
    public static func enclosingObject(
        in text: [UInt8], at pos: Int, accept: ([String: Any]) -> Bool
    ) -> (value: [String: Any], start: Int)? {
        var tries = 0
        var cursor = lastIndex(of: openBrace, in: text, atOrBefore: pos)
        while let i = cursor, pos - i <= maxLookback, tries < maxTries {
            tries += 1
            let end = balancedEnd(text, i)
            // end <= pos: closes before the marker, a sibling rather than an ancestor.
            if end > pos, let o = parseJSON(text, i..<end) as? [String: Any], accept(o) {
                return (o, i)
            }
            cursor = i > 0 ? lastIndex(of: openBrace, in: text, atOrBefore: i - 1) : nil
        }
        return nil
    }

    /// RSC rows are `<hex id>:<json>` lines; resolve a `"$<id>"` reference to its row's value.
    private static func rowValue(_ text: [UInt8], id: String) -> Any? {
        let head = Array("\(id):".utf8)
        var candidates: [Int] = []
        if matches(text, at: 0, head) { candidates.append(0) }
        candidates += offsets(of: "\n\(id):", in: text).map { $0 + 1 }
        for c in candidates {
            let start = c + head.count
            guard start < text.count, text[start] == openBrace || text[start] == openBracket else { continue }
            let end = balancedEnd(text, start)
            if end < 0 { return nil }
            return parseJSON(text, start..<end)
        }
        return nil
    }

    private static let refPattern = ScrapingText.regex(#"^\$([0-9a-f]+)$"#)

    /// Undo RSC string encodings inside a spec: "$undefined" (→ nil, dropped from objects, null in arrays),
    /// "$$" escapes, and "$<id>" row references.
    public static func resolve(_ value: Any?, in text: [UInt8]) -> Any? {
        resolve(value, text, depth: 0)
    }

    private static func resolve(_ v: Any?, _ text: [UInt8], depth: Int) -> Any? {
        guard let v else { return nil }
        if depth > 20 { return v }
        if let s = v as? String {
            if s == "$undefined" { return nil }
            if s.hasPrefix("$$") { return String(s.dropFirst()) }
            if let id = ScrapingText.firstGroups(refPattern, s)?[1] {
                return resolve(rowValue(text, id: id), text, depth: depth + 1)
            }
            return s
        }
        if let a = v as? [Any] {
            return a.map { resolve($0, text, depth: depth + 1) ?? NSNull() }
        }
        if let o = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in o {
                if let r = resolve(x, text, depth: depth + 1) { out[k] = r }
            }
            return out
        }
        return v
    }

    private static let textChild = ScrapingText.regex(#""children":\[?"((?:[^"\\]|\\.){40,})""#)
    private static let rowHead = ScrapingText.regex(#"^([0-9a-f]+):"#)

    private static func string(_ text: [UInt8], _ range: Range<Int>) -> String {
        let lo = max(0, min(range.lowerBound, text.count)), hi = max(lo, min(range.upperBound, text.count))
        return String(decoding: text[lo..<hi], as: UTF8.self)
    }

    /// The last run of rendered text (a paragraph's `"children":"..."`, 40+ characters) before `pos` in
    /// page order. When `pos` sits in its own row (`1e9:[...]`) near the row's start, the text before the
    /// place that row is referenced (`"$L1e9"`) is used instead: rows arrive out of page order.
    public static func textBefore(_ text: [UInt8], _ pos: Int) -> String? {
        let p = max(0, min(pos, text.count))
        let lineStart = (p > 0 ? lastIndex(of: newline, in: text, atOrBefore: p - 1).map { $0 + 1 } : nil) ?? 0
        var end = p
        if let id = ScrapingText.firstGroups(rowHead, string(text, lineStart..<(lineStart + 16)))?[1],
           lastText(string(text, lineStart..<p)) == nil {
            let ref = ["\"$L\(id)\"", "\"$\(id)\""].lazy.compactMap { offsets(of: $0, in: text).first }.first
            if let ref { end = ref }
        }
        return lastText(string(text, max(0, end - 200_000)..<end))
    }

    private static func lastText(_ s: String) -> String? {
        guard let last = ScrapingText.allGroups(textChild, s, group: 1).last else { return nil }
        return ScrapingText.jsonStringLiteral(last)
    }
}
