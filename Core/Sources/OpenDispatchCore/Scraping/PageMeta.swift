import Foundation
import SwiftSoup

/// Page metadata shared by scraped page sources and the refresh-time thumbnail backfill
/// (port of src/lib/page-meta.ts and `toDate` from src/lib/scrape.ts): Open Graph / Twitter
/// meta tags and JSON-LD. Pure helpers; the network half lives in DefaultPageScraper.
public enum PageMeta {
    /// THUMB_TIMEOUT_MS.
    public static let thumbTimeout: TimeInterval = 6
    /// Stop reading a page after this many bytes if </head> hasn't come yet (MAX_HEAD_BYTES).
    public static let maxHeadBytes = 200_000

    /// Lookup over a page's `<meta>` tags by property / name / itemprop (case-insensitive, first wins).
    public struct Reader: Sendable, Hashable {
        public let map: [String: String]

        /// Keys must already be lowercased.
        public init(_ map: [String: String]) { self.map = map }

        /// The first non-empty value among `keys`.
        public func callAsFunction(_ keys: String...) -> String? { value(keys) }

        public func value(_ keys: [String]) -> String? {
            for k in keys {
                if let v = map[k.lowercased()], !v.isEmpty { return v }
            }
            return nil
        }
    }

    /// metaReader(document).
    public static func meta(in doc: Document) -> Reader {
        var map: [String: String] = [:]
        guard let metas = try? doc.select("meta[content]") else { return Reader(map) }
        for m in metas {
            // `getAttribute(a) ?? getAttribute(b)`: an attribute that is present but empty still wins.
            let keyAttr = ["property", "name", "itemprop"].first { m.hasAttr($0) }
            let key = ((keyAttr.flatMap { try? m.attr($0) }) ?? "").lowercased()
            let v = ((try? m.attr("content")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !v.isEmpty, map[key] == nil { map[key] = v }
        }
        return Reader(map)
    }

    private static let articleTypes: Set<String> = [
        "Article", "NewsArticle", "BlogPosting", "TechArticle", "Report", "ScholarlyArticle", "AnalysisNewsArticle", "PressRelease",
    ]

    /// The page's JSON-LD article node (looks inside arrays and @graph).
    public static func ldArticle(in doc: Document) -> [String: Any]? {
        var nodes: [[String: Any]] = []
        func walk(_ v: Any, depth: Int) {
            guard depth < 64 else { return }
            if let a = v as? [Any] {
                for x in a { walk(x, depth: depth + 1) }
            } else if let o = v as? [String: Any] {
                nodes.append(o)
                if let g = o["@graph"], !(g is NSNull) { walk(g, depth: depth + 1) }
            }
        }
        guard let scripts = try? doc.select("script") else { return nil }
        for s in scripts where ((try? s.attr("type")) ?? "") == "application/ld+json" {
            guard let data = s.data().data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            walk(json, depth: 0)
        }
        return nodes.first { n in
            let t = n["@type"]
            let types: [Any] = (t as? [Any]) ?? [t as Any]
            return types.contains { ($0 as? String).map(articleTypes.contains) ?? false }
        }
    }

    /// ldImage: first of an array, `.url` of an object, or a string.
    public static func ldImage(_ v: Any?) -> String? {
        if let a = v as? [Any] { return ldImage(a.first) }
        if let o = v as? [String: Any] { return ScrapingText.str(o["url"]) }
        return ScrapingText.str(v)
    }

    /// `new URL(u, base).toString()`, or nil.
    public static func absURL(_ u: String?, base: String) -> String? {
        guard let u, !u.isEmpty else { return nil }
        let baseURL = URL(string: base)
        guard let url = URL(string: u, relativeTo: baseURL)?.absoluteURL, url.scheme != nil else { return nil }
        return url.absoluteString
    }

    private static let imageKeys = ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"]

    /// Absolute http(s) URL of the page's share image: og:image, twitter:image, then JSON-LD image.
    public static func pageImage(_ meta: Reader, ld: [String: Any]?, pageURL: String) -> String? {
        guard let u = absURL(meta.value(imageKeys) ?? ldImage(ld?["image"]), base: pageURL) else { return nil }
        let lower = u.lowercased()
        // A sharing crop with a logo stamped on it becomes the page's own picture (LeadImage.clean).
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? LeadImage.clean(u) : nil
    }

    /// Share image from page HTML (a full page or just its <head>).
    public static func imageFromHTML(_ html: String, pageURL: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html, pageURL) else { return nil }
        return pageImage(meta(in: doc), ld: ldArticle(in: doc), pageURL: pageURL)
    }

    /// Share image from a flat meta map, as Jina Reader's JSON `metadata` returns it.
    public static func imageFromMetaMap(_ map: [String: Any], pageURL: String) -> String? {
        var lower: [String: String] = [:]
        for (k, v) in map {
            if let s = ScrapingText.str(v) { lower[k.lowercased()] = s }
        }
        return pageImage(Reader(lower), ld: nil, pageURL: pageURL)
    }

    // MARK: - Dates (scrape.ts toDate)

    private static let hasTime = ScrapingText.regex(#"\d:\d|T\d"#, [.caseInsensitive])
    private static let trailingZone = ScrapingText.regex(
        #"(?:\s+(?:GMT|UTC|UT|[ECMP][SD]T)(?:\s*[+-]\d{2}:?\d{2})?|\s+[+-]\d{2}:?\d{2}|(?<=\d)Z)\s*$"#, [.caseInsensitive])

    /// Parse a published date. A date with no time ("2026-10-21", "October 21, 2026") is pinned to
    /// noon UTC on that calendar day, and never later than `now`. Full timestamps are kept as given.
    /// Nonsense (more than 2 days ahead, or before 1995) is nil.
    public static func toDate(_ value: String?, now: Date = Date()) -> Date? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        guard var d = PageMetaDate.parse(v) else { return nil }
        let dateOnly = !ScrapingText.test(hasTime, v)
        if dateOnly {
            // A zone on a date with no time names no instant, only the day.
            let bare = ScrapingText.replace(trailingZone, in: v, with: "")
            let day = PageMetaDate.calendarDay(bare) ?? PageMetaDate.localDay(d)
            if let noon = PageMetaDate.noonUTC(day) { d = noon }
        }
        if d.timeIntervalSince(now) > 2 * 86_400 { return nil }
        if Calendar.current.component(.year, from: d) < 1995 { return nil }
        if dateOnly && d > now { d = now }
        return d
    }
}

/// A permissive date parser approximating JavaScript's `new Date(string)` for the forms pages use:
/// ISO 8601 (date-only = UTC, date-time without zone = local), RFC 1123/2822, "October 21, 2026",
/// "21 Oct 2026", "2026/10/21", "10/21/2026", and `Date.prototype.toString()` output.
enum PageMetaDate {
    struct Day: Hashable { var year: Int; var month: Int; var day: Int }

    private static let iso = ScrapingText.regex(
        #"^([+-]?\d{4,6})(?:-(\d{1,2})(?:-(\d{1,2}))?)?(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#,
        [.caseInsensitive])
    private static let isoDateOnly = ScrapingText.regex(#"^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$"#)
    private static let parenthetical = ScrapingText.regex(#"\s*\([^)]*\)\s*$"#)
    private static let weekday = ScrapingText.regex(
        #"^(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(?:day|nesday|sday|urday)?\.?,?\s+"#, [.caseInsensitive])
    private static let zoneSuffix = ScrapingText.regex(
        #"\s*(?:(?:(GMT|UTC|UT)\s*([+-]\d{2}):?(\d{2})?)|(GMT|UTC|UT|Z)|([ECMP][SD]T)|([+-]\d{2}):?(\d{2}))$"#, [.caseInsensitive])
    private static let septs = ScrapingText.regex(#"\bSept\b"#, [.caseInsensitive])

    private static let usZones: [String: Int] = [
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
    ]

    private static let formats = [
        "d MMM yyyy HH:mm:ss", "d MMM yyyy HH:mm", "d MMMM yyyy HH:mm:ss", "d MMMM yyyy HH:mm",
        "d MMM yyyy", "d MMMM yyyy",
        "MMM d yyyy HH:mm:ss", "MMM d, yyyy HH:mm:ss", "MMMM d, yyyy HH:mm:ss", "MMM d, yyyy HH:mm", "MMMM d, yyyy HH:mm",
        "MMM d, yyyy h:mm a", "MMMM d, yyyy h:mm a", "MMM d, yyyy, h:mm a", "MMMM d, yyyy, h:mm a",
        "MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "MMMM d yyyy", "MMM yyyy", "MMMM yyyy",
        "yyyy/M/d HH:mm:ss", "yyyy/M/d HH:mm", "yyyy/M/d", "M/d/yyyy HH:mm:ss", "M/d/yyyy HH:mm", "M/d/yyyy h:mm a", "M/d/yyyy",
    ]

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    /// `new Date(s)`; nil for NaN.
    static func parse(_ raw: String) -> Date? {
        let s = ScrapingText.collapse(raw)
        if let g = ScrapingText.firstGroups(iso, s) { return parseISO(g) }
        return parseLoose(s)
    }

    private static func int(_ s: String?) -> Int? { s.flatMap { Int($0) } }

    private static func parseISO(_ g: [String?]) -> Date? {
        guard let year = int(g[1]) else { return nil }
        let month = int(g[2]) ?? 1, day = int(g[3]) ?? 1
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var c = DateComponents(year: year, month: month, day: day)
        let hasClock = g[4] != nil
        if hasClock {
            c.hour = int(g[4]); c.minute = int(g[5]); c.second = int(g[6]) ?? 0
            if let frac = g[7] {
                let ms = Int((frac + "000").prefix(3)) ?? 0
                c.nanosecond = ms * 1_000_000
            }
            guard let h = c.hour, h <= 24, let mi = c.minute, mi < 60, (c.second ?? 0) < 61 else { return nil }
        }
        var cal = Calendar(identifier: .gregorian)
        if let z = g[8] {
            guard let off = offsetSeconds(z) else { return nil }
            guard let tz = TimeZone(secondsFromGMT: off) else { return nil }
            cal.timeZone = tz
        } else {
            // ISO date-only parses as UTC; a date-time without zone as local time.
            cal.timeZone = hasClock ? .current : utc
        }
        return validDate(c, cal)
    }

    /// Build a date only when the components round-trip (no Feb 30 rolling into March).
    private static func validDate(_ c: DateComponents, _ cal: Calendar) -> Date? {
        guard let d = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: d)
        guard back.year == c.year, back.month == c.month, back.day == c.day else { return nil }
        return d
    }

    /// "Z", "+05:30", "+0530", "-08".
    private static func offsetSeconds(_ z: String) -> Int? {
        if z.uppercased() == "Z" { return 0 }
        let sign = z.hasPrefix("-") ? -1 : 1
        let digits = z.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 2 || digits.count == 4, let h = Int(digits.prefix(2)) else { return nil }
        let m = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
        return sign * (h * 3600 + m * 60)
    }

    private static func parseLoose(_ input: String) -> Date? {
        var s = ScrapingText.replace(parenthetical, in: input, with: "")
        s = ScrapingText.replace(weekday, in: s, with: "")
        s = ScrapingText.replace(septs, in: s, with: "Sep")
        var offset: Int?
        if let m = zoneSuffix.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
            if let h = group(2) {
                offset = offsetSeconds(h + (group(3) ?? "00"))
            } else if group(4) != nil {
                offset = 0
            } else if let us = group(5), let hours = usZones[us.uppercased()] {
                offset = hours * 3600
            } else if let h = group(6), let mm = group(7) {
                offset = offsetSeconds(h + mm)
            }
            if offset != nil { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard !s.isEmpty, let wall = wallClock(s) else { return nil }
        // `wall` holds the written clock time as if it were UTC; shift it into the right zone.
        if let offset { return wall.addingTimeInterval(TimeInterval(-offset)) }
        let local = TimeZone.current.secondsFromGMT(for: wall)
        return wall.addingTimeInterval(TimeInterval(-local))
    }

    /// The written date/time read as UTC wall-clock time.
    private static func wallClock(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.isLenient = false
        for format in formats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// The calendar day a date-only string names, or nil when it doesn't parse.
    static func calendarDay(_ bare: String) -> Day? {
        let s = ScrapingText.collapse(bare)
        if let g = ScrapingText.firstGroups(isoDateOnly, s), let y = int(g[1]) {
            let day = Day(year: y, month: int(g[2]) ?? 1, day: int(g[3]) ?? 1)
            return noonUTC(day) == nil ? nil : day
        }
        guard let d = parse(s) else { return nil }
        if ScrapingText.test(iso, s) { return utcDay(d) }
        return localDay(d)
    }

    static func utcDay(_ d: Date) -> Day {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: d)
        return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func localDay(_ d: Date) -> Day {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func noonUTC(_ day: Day) -> Date? {
        validDate(DateComponents(year: day.year, month: day.month, day: day.day, hour: 12), utcCalendar)
    }
}
