import Foundation

/// Next.js RSC payload helpers for the extractor (port of the parts of src/lib/rsc.ts and src/lib/payload-videos.ts
/// that extract.ts uses). Video players mounted client-side (openai.com's Vimeo media items) may be missing from the
/// server HTML; their props are in the `self.__next_f.push([1,"..."])` payload. Positions are UTF-8 byte offsets.
enum ExtractionPayload {
    typealias P = ExtractionDOM.Pattern

    struct Video: Sendable, Hashable {
        var src: String
        /// The Vimeo/YouTube video id: what identifies this video in a page's HTML.
        var key: String
        var title: String?
        /// Texts that name it on the page: the player's alt text, the poster image's title.
        var names: [String]
        /// The poster's file name, as it appears in a poster <img src>.
        var posterFile: String?
        /// The last paragraph of text before the player in page order.
        var anchor: String?
    }

    private static let push = P("self\\.__next_f\\.push\\(\\[\\s*1\\s*,\\s*(\"(?:[^\"\\\\]|\\\\.)*\")\\s*\\]\\)")
    private static let marker = P("\"videoEmbedUrl\"\\s*:\\s*\"")
    private static let embed = P("^https://(?:player\\.vimeo\\.com/video/|(?:www\\.)?youtube(?:-nocookie)?\\.com/embed/)([\\w-]+)")
    private static let textChild = P("\"children\":\\[?\"((?:[^\"\\\\]|\\\\.){40,})\"")
    private static let rowPrefix = P("^([0-9a-f]+):")
    static let maxLookback = 2_000_000
    static let maxTries = 20_000

    /// Decode a JSON string literal (with its quotes).
    static func jsonString(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// The RSC stream: every pushed string chunk, decoded and joined in order.
    static func rscPayload(_ html: String) -> String {
        push.allMatches(html).compactMap { $0[1].flatMap(jsonString) }.joined()
    }

    /// Index just past the JSON object/array that opens at `start`, or -1 if it never closes.
    static func balancedEnd(_ bytes: [UInt8], _ start: Int) -> Int {
        guard start >= 0, start < bytes.count else { return -1 }
        let open = bytes[start]
        guard open == UInt8(ascii: "{") || open == UInt8(ascii: "[") else { return -1 }
        var depth = 0
        var inString = false
        var i = start
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                depth += 1
            } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return -1
    }

    private static func lastIndex(of byte: UInt8, in bytes: [UInt8], atOrBefore pos: Int) -> Int {
        var i = min(pos, bytes.count - 1)
        while i >= 0 {
            if bytes[i] == byte { return i }
            i -= 1
        }
        return -1
    }

    /// The innermost JSON object around `pos` that parses and passes `accept`, with where it starts.
    static func enclosingObjectAt(_ bytes: [UInt8], _ pos: Int, accept: ([String: Any]) -> Bool) -> (value: [String: Any], start: Int)? {
        var tries = 0
        var i = lastIndex(of: UInt8(ascii: "{"), in: bytes, atOrBefore: pos)
        while i >= 0 && pos - i <= maxLookback && tries < maxTries {
            tries += 1
            let end = balancedEnd(bytes, i)
            if end > pos,
               let obj = (try? JSONSerialization.jsonObject(with: Data(bytes[i..<end]))) as? [String: Any],
               accept(obj) {
                return (obj, i)
            }
            i = lastIndex(of: UInt8(ascii: "{"), in: bytes, atOrBefore: i - 1)
        }
        return nil
    }

    private static func string(_ bytes: [UInt8], _ from: Int, _ to: Int) -> String {
        let lo = max(0, min(from, bytes.count)), hi = max(lo, min(to, bytes.count))
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    private static func lastText(_ s: String) -> String? {
        guard let last = textChild.allMatches(s).last, let raw = last[1] else { return nil }
        return jsonString("\"\(raw)\"")
    }

    private static func indexOf(_ needle: String, in bytes: [UInt8]) -> Int? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, n.count <= bytes.count else { return nil }
        var i = 0
        let limit = bytes.count - n.count
        while i <= limit {
            if bytes[i] == n[0] && bytes[i..<(i + n.count)].elementsEqual(n) { return i }
            i += 1
        }
        return nil
    }

    /// The last run of rendered text (40+ characters) before `pos` in page order; rows referenced elsewhere use the
    /// text before their reference.
    static func textBefore(_ bytes: [UInt8], _ pos: Int) -> String? {
        let nl = lastIndex(of: UInt8(ascii: "\n"), in: bytes, atOrBefore: pos)
        let lineStart = nl + 1
        var end = pos
        if let row = rowPrefix.firstMatch(string(bytes, lineStart, lineStart + 16)), let id = row[1],
           lastText(string(bytes, lineStart, pos)) == nil {
            if let ref = ["\"$L\(id)\"", "\"$\(id)\""].lazy.compactMap({ indexOf($0, in: bytes) }).first { end = ref }
        }
        return lastText(string(bytes, max(0, end - 200_000), end))
    }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// findPayloadVideos(html).
    static func videos(in html: String) -> [Video] {
        guard html.contains("videoEmbedUrl") else { return [] }
        let text = rscPayload(html)
        guard !text.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        let ns = text as NSString
        var out: [Video] = []
        for m in marker.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: text) else { continue }
            let pos = text.utf8.distance(from: text.startIndex, to: r.lowerBound)
            guard let found = enclosingObjectAt(bytes, pos, accept: { $0["videoEmbedUrl"] is String }) else { continue }
            let o = found.value
            guard let src = str(o["videoEmbedUrl"]), let key = embed.firstMatch(src)?[1] ?? nil,
                  !out.contains(where: { $0.key == key }) else { continue }
            let poster = o["posterImage"] as? [String: Any] ?? [:]
            let file = poster["file"] as? [String: Any] ?? [:]
            let posterURL = str(file["url"])
            out.append(Video(
                src: src,
                key: key,
                title: str(o["videoEmbedTitle"]),
                names: [str(o["altText"]), str(poster["title"])].compactMap { $0 },
                posterFile: str(file["fileName"]) ?? posterURL.flatMap { $0.split(separator: "/").last.map(String.init) },
                anchor: textBefore(bytes, found.start)
            ))
        }
        return out
    }
}
