import Foundation

/// OPML 2.0 import/export (port of src/lib/opml.ts). A small tokenizer over `<outline>` tags is
/// enough for subscription lists and, unlike a strict XML parser, tolerates the malformed exports
/// found in the wild while still decoding entities in attributes.
public struct DefaultOPMLCoder: OPMLCoding {
    public init() {}

    /// Namespace for the non-standard `openfeed:kind` attribute, so scraped pages and podcasts round-trip.
    public static let namespace = "https://github.com/gautham-v/openfeed"

    // MARK: - Serialize

    /// Folders (in the order given, empty ones left out) as nested outlines, then unfiled sources at
    /// the top level. Sources whose folder isn't in `folders` are exported unfiled rather than dropped.
    public func serialize(folders: [Folder], sources: [Source], now: Date) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0" xmlns:openfeed="\#(Self.namespace)">"#,
            "  <head>",
            "    <title>OpenDispatch subscriptions</title>",
            "    <dateCreated>\(Self.utcString(now))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        let known = Set(folders.map(\.id))
        for f in folders {
            let list = sources.filter { $0.folderId == f.id }
            if list.isEmpty { continue }
            let t = Self.escape(f.title)
            lines.append(#"    <outline text="\#(t)" title="\#(t)">"#)
            lines.append(contentsOf: list.map { Self.feedOutline($0, indent: "      ") })
            lines.append("    </outline>")
        }
        lines.append(contentsOf: sources.filter { s in s.folderId.map { !known.contains($0) } ?? true }
            .map { Self.feedOutline($0, indent: "    ") })
        lines.append(contentsOf: ["  </body>", "</opml>", ""])
        return lines.joined(separator: "\n")
    }

    static func feedOutline(_ s: Source, indent: String) -> String {
        let t = escape(s.title)
        return #"\#(indent)<outline type="rss" text="\#(t)" title="\#(t)" xmlUrl="\#(escape(s.feedUrl))" htmlUrl="\#(escape(s.url))" openfeed:kind="\#(s.kind.rawValue)"/>"#
    }

    /// Attribute escaping; runs of CR/LF/tab become one space, and characters XML 1.0 forbids (other
    /// C0 controls, U+FFFE/U+FFFF), which feed titles occasionally carry, are dropped so the export
    /// stays well-formed for strict readers.
    static func escape(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { c in
            c.value >= 0x20 ? (c.value != 0xFFFE && c.value != 0xFFFF) : (c == "\t" || c == "\n" || c == "\r")
        }))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacing(#/[\r\n\t]+/#.matchingSemantics(.unicodeScalar), with: " ")
    }

    /// JS `Date.prototype.toUTCString()`: "Sat, 24 Oct 2026 12:00:00 GMT".
    static func utcString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    // MARK: - Parse

    /// Parse an OPML document. Outlines with an `xmlUrl` (or `url`) are feeds (a `type` attribute
    /// isn't required); outlines without one are folders. Openfeed folders are flat, so a feed goes in
    /// its nearest enclosing folder, and folders with the same title (any case) are merged. Duplicate
    /// feeds keep their first occurrence. Throws when the text has no OPML body.
    public func parse(_ xml: String) throws -> OPMLDocument {
        // Comments and CDATA could hide or fake outline tags.
        let text = xml.replacing(#/<!--[\s\S]*?-->/#, with: "").replacing(#/<!\[CDATA\[[\s\S]*?\]\]>/#, with: "")
        guard text.contains(#/<opml\b/#.ignoresCase()),
              let bodyStart = text.firstRange(of: #/<body\b[^>]*>/#.ignoresCase()) else {
            throw OPMLError.notOPML
        }
        let body = text[bodyStart.lowerBound...]

        var doc = OPMLDocument()
        var folderIndex: [String: Int] = [:]
        var seen = Set<String>()
        // Folder title (or nil) for each open outline; feeds that wrap children push their parent's.
        var stack: [String?] = []

        let tag = #/<(\/?)outline\b((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/#.ignoresCase().matchingSemantics(.unicodeScalar)
        for m in body.matches(of: tag) {
            if !m.1.isEmpty {
                _ = stack.popLast()
                continue
            }
            let a = Self.attributes(String(m.2))
            let selfClosing = !m.3.isEmpty
            let parent: String? = stack.last ?? nil
            if let src = Self.source(from: a) {
                if !seen.contains(src.feedUrl) {
                    seen.insert(src.feedUrl)
                    if let parent {
                        let key = parent.lowercased()
                        if let i = folderIndex[key] {
                            doc.folders[i].sources.append(src)
                        } else {
                            folderIndex[key] = doc.folders.count
                            doc.folders.append(OPMLFolder(title: parent, sources: [src]))
                        }
                    } else {
                        doc.unfiled.append(src)
                    }
                }
                if !selfClosing { stack.append(parent) }
            } else if !selfClosing {
                // A folder; an untitled one passes its parent's folder through.
                stack.append(Self.nonEmpty(a["title"]) ?? Self.nonEmpty(a["text"]) ?? parent)
            }
        }
        return doc
    }

    /// Attributes keyed by lowercased name (OPML in the wild mixes `xmlUrl`, `xmlurl`, `XMLURL`);
    /// values entity-decoded and trimmed. A repeated name keeps the last value, as in the web app.
    static func attributes(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in raw.matches(of: #/([\w:.\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/#.matchingSemantics(.unicodeScalar)) {
            let value = String(m.2 ?? m.3 ?? "")
            out[String(m.1).lowercased()] = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static func source(from a: [String: String]) -> OPMLSource? {
        guard var feedURL = nonEmpty(a["xmlurl"]) ?? nonEmpty(a["url"]) else { return nil }
        // `feed://` and `feed:https://` are old subscribe-link schemes for plain http(s).
        feedURL = feedURL.replacing(#/^(?i:feed):(\/\/)?(?=(?i:https?):)/#, with: "")
        feedURL = feedURL.replacing(#/^(?i:feed):\/\//#, with: "https://")
        return OPMLSource(
            title: nonEmpty(a["title"]) ?? nonEmpty(a["text"]) ?? "",
            feedUrl: feedURL,
            htmlUrl: nonEmpty(a["htmlurl"]),
            kind: a["openfeed:kind"].flatMap(SourceKind.init(rawValue:)))
    }

    // MARK: - Entities

    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]

    /// Decode entities; a second pass undoes the double escaping some exporters do (`&amp;amp;`).
    public static func decodeEntities(_ s: String) -> String {
        let once = decodeOnce(s)
        return once.contains(#/&(amp|lt|gt|quot|apos|#\d+|#[xX][0-9a-fA-F]+);/#.ignoresCase()) ? decodeOnce(once) : once
    }

    private static func decodeOnce(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacing(#/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);/#) { m -> String in
            let e = m.1
            if e.hasPrefix("#") {
                let digits = e.dropFirst()
                let n: UInt32?
                if digits.first == "x" || digits.first == "X" {
                    n = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    n = UInt32(digits, radix: 10)
                }
                if let n, n > 0, n <= 0x10FFFF, let scalar = Unicode.Scalar(n) { return String(Character(scalar)) }
                return String(m.0)
            }
            return named[e.lowercased()] ?? String(m.0)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

public enum OPMLError: Error, LocalizedError, Equatable, Sendable {
    case notOPML

    public var errorDescription: String? {
        switch self {
        case .notOPML: "Not an OPML file"
        }
    }
}
