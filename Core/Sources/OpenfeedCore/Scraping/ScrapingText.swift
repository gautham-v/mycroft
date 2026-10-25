import Foundation

/// Small string/regex helpers shared by the Scraping files (internal; namespaced to avoid collisions).
enum ScrapingText {
    /// Compile a constant pattern. Patterns are literals in this module, so failure is a programmer error.
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Capture groups of the first match (index 0 = whole match); nil when no match.
    static func firstGroups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }

    /// All matches' capture group `group`.
    static func allGroups(_ re: NSRegularExpression, _ s: String, group: Int) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    /// JavaScript `s.split(re)` for patterns without capture groups ("" splits to [""]).
    static func split(_ s: String, by re: NSRegularExpression) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), !r.isEmpty else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }

    static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static let whitespaceRun = regex(#"\s+"#)

    /// `s.replace(/\s+/g, " ").trim()`
    static func collapse(_ s: String) -> String {
        replace(whitespaceRun, in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// page-meta `str`: a non-blank string, trimmed; anything else nil.
    static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// scrape.ts `clip`: collapse whitespace, nil when empty, cut to `max` with an ellipsis.
    static func clip(_ s: String?, _ max: Int) -> String? {
        guard let s else { return nil }
        let t = collapse(s)
        if t.isEmpty { return nil }
        guard t.count > max else { return t }
        let cut = String(t.prefix(max - 1))
        return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
    }

    /// Decode the body of a JSON string literal (the text between the quotes).
    static func jsonStringLiteral(_ body: String) -> String? {
        guard let data = "\"\(body)\"".data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}
