import Foundation

/// Pure helpers from src/lib/parse.ts, public so the fetcher, detector and extractor can reuse them.
public enum FeedParsingSupport {
    // MARK: YouTube / HN

    /// youtubeThumb: `https://i.ytimg.com/vi/<id>/hqdefault.jpg`.
    public static func youtubeThumbnail(videoID: String) -> String {
        "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
    }

    /// isHnFeed: the feed is served by hnrss.org (or a subdomain).
    public static func isHNFeed(_ feedURL: String) -> Bool {
        guard let host = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "hnrss.org" || host.hasSuffix(".hnrss.org")
    }

    /// parseHnDescription: "Points: 123" and "# Comments: 45" in an hnrss description.
    public static func parseHNDescription(_ desc: String?) -> (points: Int?, comments: Int?) {
        guard let desc, !desc.isEmpty else { return (nil, nil) }
        let text = decodeBasicEntities(desc.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
        return (firstInt(#"Points:\s*(\d+)"#, in: text), firstInt(#"#\s*Comments:\s*(\d+)"#, in: text))
    }

    // MARK: Podcasts

    private static let audioExtension = #"\.(mp3|m4a|aac|ogg|oga|opus|wav|flac)(\?|#|$)"#

    /// audioEnclosure: the enclosure URL when it is audio (an audio/* type; or, with no type or
    /// application/octet-stream, an audio file extension).
    public static func audioEnclosure(url: String?, type: String?) -> String? {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        let type = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let audioExt = matches(audioExtension, url)
        if !type.isEmpty {
            return type.hasPrefix("audio/") || (type == "application/octet-stream" && audioExt) ? url : nil
        }
        return audioExt ? url : nil
    }

    /// parseDuration: itunes:duration as seconds, from "3725", "3725.4", "MM:SS" or "HH:MM:SS". nil when 0 or invalid.
    public static func parseDuration(_ value: String?) -> Int? {
        guard let s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 3, parts.allSatisfy({ matches(#"^\d+(\.\d+)?$"#, $0) }) else { return nil }
        let secs = parts.reduce(0.0) { acc, p in acc * 60 + (Double(p) ?? 0) }
        guard secs > 0, secs.isFinite, secs < Double(Int.max) else { return nil }
        return Int(secs.rounded())
    }

    /// RSS 2.0 `<author>` is "email (Name)": show the name. A bare email gives way to `fallback`
    /// (itunes:author) when there is one. parse.ts showed the raw element.
    public static func displayAuthor(_ author: String?, fallback: String?) -> String? {
        let fallback = nonEmpty(fallback)
        guard let a = nonEmpty(author) else { return fallback }
        if let m = a.firstMatch(of: #/^[^\s@()]+@[^\s@()]+\s*\((.+)\)$/#), let name = nonEmpty(String(m.1)) { return name }
        if a.wholeMatch(of: #/(?:mailto:)?[^\s@()]+@[^\s@()]+/#) != nil { return fallback ?? a }
        return a
    }

    /// feedLooksLikePodcast: some audio, and either most items have it or the channel has iTunes tags
    /// and at least a quarter do. A blog that links the odd MP3 stays a blog.
    public static func feedLooksLikePodcast(hasItunesTags: Bool, itemCount: Int, audioCount: Int) -> Bool {
        if audioCount == 0 { return false }
        return audioCount * 2 >= itemCount || (hasItunesTags && audioCount * 4 >= itemCount)
    }

    // MARK: Text

    /// stripHtml(html, max): drop script/style, tags, decode the basic entities, collapse whitespace,
    /// truncate to `max` characters with an ellipsis. nil when nothing is left.
    public static func stripHTML(_ html: String?, max: Int = 400) -> String? {
        guard var s = html, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeBasicEntities(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        guard s.count > max, max > 1 else { return s }
        let cut = String(s.prefix(max - 1))
        return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
    }

    /// decodeEntities in parse.ts: only &lt; &gt; &quot; &#39; &#x27; &nbsp; &amp; (in that order, &amp; last).
    public static func decodeBasicEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Full HTML entity decoding (numeric and common named entities), like rss-parser's contentSnippet.
    public static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&"), let re = entityRegex else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            if let scalar = entityScalar(body) {
                out.unicodeScalars.append(scalar)
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// rss-parser's contentSnippet: tags removed, then entities decoded.
    static func snippet(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return decodeHTMLEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// firstImg: the src of the first <img> in an HTML string.
    static func firstImage(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        return firstGroup(#"<img[^>]+src=["']([^"']+)["']"#, in: html, options: .caseInsensitive)
    }

    // MARK: URLs

    /// absolutize(u, base): resolve against `base` (after decoding HTML entities, so a WordPress `&#038;` stays
    /// in the query instead of starting a fragment), WHATWG-style
    /// normalization for http(s) (lower-case host, "/" for an empty path, dot segments removed). nil when invalid.
    public static func absolutize(_ u: String?, base: String?) -> String? {
        guard let u else { return nil }
        let raw = decodeHTMLEntities(u).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        let baseURL = base.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.scheme == nil ? nil : $0 }
        guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), !scheme.isEmpty
        else { return nil }
        guard scheme == "http" || scheme == "https" else { return resolved.absoluteString }
        guard var comps = URLComponents(url: resolved.standardized, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty
        else { return nil }
        comps.scheme = scheme
        comps.host = host.lowercased()
        if comps.percentEncodedPath.isEmpty { comps.percentEncodedPath = "/" }
        if (scheme == "http" && comps.port == 80) || (scheme == "https" && comps.port == 443) { comps.port = nil }
        return comps.string ?? resolved.absoluteString
    }

    /// findFeedItemHtml's link key: trimmed, fragment removed, first run of slashes before the query or end removed.
    static func linkMatchKey(_ u: String) -> String {
        var s = u.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        if let r = s.range(of: #"/+(?=\?|$)"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    // MARK: Dates

    /// Lenient feed date parsing (RFC 822 and ISO 8601 variants), standing in for JavaScript's `new Date(s)`.
    public static func date(from string: String?) -> Date? {
        guard var s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if matches(#"^\d{4}-\d{2}-\d{2}"#, s) { return isoDate(s) }
        return rfc822Date(s)
    }

    private static func isoDate(_ input: String) -> Date? {
        if let d = ISO8601.date(from: input) { return d }
        var s = input.replacingOccurrences(of: #"^(\d{4}-\d{2}-\d{2}) "#, with: "$1T", options: .regularExpression)
        if s.range(of: #"T\d{2}:\d{2}"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: #"(\d{2}:\d{2}(?::\d{2})?)\.\d+"#, with: "$1", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d{2}:\d{2}(?::\d{2})?)\s*([+-]\d{2})(\d{2})$"#, with: "$1$2:$3", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d{2}:\d{2}(?::\d{2})?)\s*([+-]\d{2})$"#, with: "$1$2:00", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(?i)\s*(UTC|GMT|z)$"#, with: "Z", options: .regularExpression)
        }
        for f in isoFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static let zoneOffsets: [String: String] = [
        "UT": "+0000", "UTC": "+0000", "GMT": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "CET": "+0100", "CEST": "+0200", "BST": "+0100", "IST": "+0530", "JST": "+0900", "AEST": "+1000", "AEDT": "+1100",
    ]

    private static func rfc822Date(_ input: String) -> Date? {
        var s = input.replacingOccurrences(of: #"^[A-Za-z]+\.?,?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "October" / "Sept" -> "Oct" / "Sep".
        s = s.replacingOccurrences(of: #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?"#, with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        if let r = s.range(of: #"\(?[A-Za-z]{1,5}\)?$"#, options: .regularExpression) {
            let zone = s[r].trimmingCharacters(in: CharacterSet(charactersIn: "()")).uppercased()
            if let off = zoneOffsets[zone] {
                s.replaceSubrange(r, with: off)
            } else if s[r].count <= 5, s.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
                s.replaceSubrange(r, with: "+0000")
            }
        }
        s = s.replacingOccurrences(of: #"([+-]\d{2}):(\d{2})$"#, with: "$1$2", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for f in rfcFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        f.dateFormat = format
        f.isLenient = false
        return f
    }

    // DateFormatter is thread-safe for parsing; these are configured once and never mutated.
    private static let isoFormatters: [DateFormatter] = [
        formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", utc: true),
        formatter("yyyy-MM-dd'T'HH:mmXXXXX", utc: true),
        formatter("yyyy-MM-dd'T'HH:mm:ss", utc: false),
        formatter("yyyy-MM-dd'T'HH:mm", utc: false),
        formatter("yyyy-MM-dd", utc: true),
    ]

    private static let rfcFormatters: [DateFormatter] = [
        formatter("d MMM yyyy HH:mm:ss Z", utc: true),
        formatter("d MMM yyyy HH:mm Z", utc: true),
        formatter("d MMM yy HH:mm:ss Z", utc: true),
        formatter("d MMM yy HH:mm Z", utc: true),
        formatter("MMM d yyyy HH:mm:ss Z", utc: true),
        formatter("d MMM yyyy HH:mm:ss", utc: false),
        formatter("d MMM yyyy HH:mm", utc: false),
        formatter("MMM d yyyy HH:mm:ss", utc: false),
        formatter("d MMM yyyy", utc: false),
        formatter("MMM d yyyy", utc: false),
    ]

    // MARK: Regex helpers

    static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func firstGroup(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func firstInt(_ pattern: String, in s: String) -> Int? {
        firstGroup(pattern, in: s, options: .caseInsensitive).flatMap { Int($0) }
    }

    // MARK: Entities

    private static let entityRegex = try? NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)

    static func entityScalar(_ body: String) -> Unicode.Scalar? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init)
        }
        return namedEntities[body].flatMap(Unicode.Scalar.init)
    }

    /// Common HTML named entities (code points).
    static let namedEntities: [String: UInt32] = [
        "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "nbsp": 160,
        "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "brvbar": 166, "sect": 167, "uml": 168,
        "copy": 169, "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176,
        "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184,
        "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199,
        "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207,
        "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215,
        "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231,
        "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247,
        "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253, "thorn": 254, "yuml": 255,
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732,
        "Alpha": 913, "Beta": 914, "Gamma": 915, "Delta": 916, "Omega": 937, "alpha": 945, "beta": 946, "gamma": 947,
        "delta": 948, "epsilon": 949, "lambda": 955, "mu": 956, "pi": 960, "sigma": 963, "omega": 969,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
        "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260, "euro": 8364, "trade": 8482,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "rArr": 8658, "hArr": 8660,
        "minus": 8722, "lowast": 8727, "radic": 8730, "infin": 8734, "ne": 8800, "equiv": 8801, "le": 8804, "ge": 8805,
        "loz": 9674, "spades": 9824, "clubs": 9827, "hearts": 9829, "diams": 9830, "check": 10003,
    ]
}
