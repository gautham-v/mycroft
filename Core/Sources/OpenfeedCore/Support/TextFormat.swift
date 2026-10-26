import Foundation

/// Ports of the UI text helpers in src/components/text.ts and badge.tsx.
public enum TextFormat {
    /// Strip tags and decode the common entities; collapses whitespace.
    public static func stripHTML(_ html: String?) -> String {
        guard var s = html, !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&#x27;", with: "'")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "1:02:03" or "4:05"; nil for nil/0.
    public static func duration(_ sec: Int?) -> String? {
        guard let sec, sec > 0 else { return nil }
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        let ss = String(format: "%02d", s)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
    }

    /// "Oct 25, 2026" in the current locale.
    public static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// A post on X: the reader shows it as a post (no headline), the list leads with the author.
    public static func isXPost(_ url: String) -> Bool {
        url.range(of: #"^https?://(?:www\.|mobile\.)?(?:twitter|x)\.com/[^/]+/status/\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Kun Chen (@kunchenguid)" → ("Kun Chen", "kunchenguid").
    public static func splitHandle(_ author: String?) -> (name: String, handle: String?) {
        let a = author ?? ""
        guard let re = try? NSRegularExpression(pattern: #"^(.*?)\s*\(@([A-Za-z0-9_]+)\)\s*$"#),
              let m = re.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
              let nameR = Range(m.range(at: 1), in: a), let handleR = Range(m.range(at: 2), in: a)
        else { return (a, nil) }
        return (String(a[nameR]), String(a[handleR]))
    }

    /// Monogram letter for SourceBadge's fallback: first letter of title (minus leading "The "), else host, else "?".
    public static func monogram(title: String, host: String) -> String {
        var t = title.isEmpty ? host : title
        if t.isEmpty { t = "?" }
        if let r = t.range(of: #"^the\s+"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        return t.first.map { String($0).uppercased() } ?? "?"
    }

    /// SourceBadge fallback palette (8 colors, each >= 4.5:1 against white text), as hex strings.
    public static let badgePalette = ["#0063CC", "#3B5BA9", "#8A3FA0", "#B23A48", "#9A5B00", "#2F7A3B", "#5A5A9E", "#7A5230"]

    /// Index into `badgePalette` for a host (port of hostColor: h = h*31 + charCode, unsigned 32-bit, over UTF-16 units).
    public static func badgeColorIndex(_ host: String) -> Int {
        var h: UInt32 = 0
        for u in host.utf16 { h = h &* 31 &+ UInt32(u) }
        return Int(h % UInt32(badgePalette.count))
    }
}
