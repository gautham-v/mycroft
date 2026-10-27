import Foundation

/// The file formats a `<podcast:transcript>` can point at, in preference order (richest first).
enum TranscriptFormat: CaseIterable {
    case json, vtt, srt, html, text

    /// From the declared MIME type, else the URL's extension. nil for formats we can't read.
    static func detect(type: String?, url: String) -> TranscriptFormat? {
        let mime = (type ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch mime {
        case "application/json", "text/json": return .json
        case "text/vtt": return .vtt
        case "application/x-subrip", "application/srt", "text/srt", "application/x-srt": return .srt
        case "text/html", "application/xhtml+xml": return .html
        case "text/plain": return .text
        default: break
        }
        let path = (URL(string: url)?.path ?? url).lowercased()
        if path.hasSuffix(".json") { return .json }
        if path.hasSuffix(".vtt") { return .vtt }
        if path.hasSuffix(".srt") { return .srt }
        if path.hasSuffix(".html") || path.hasSuffix(".htm") { return .html }
        if path.hasSuffix(".txt") { return .text }
        return nil
    }

    /// The format the body itself announces ("WEBVTT", a JSON object), else the declared one.
    func sniffed(_ body: String) -> TranscriptFormat {
        let head = body.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if head.hasPrefix("WEBVTT") { return .vtt }
        if head.hasPrefix("{") || head.hasPrefix("[{") { return .json }
        return self
    }
}

/// Reading `<podcast:transcript>` files into segments, and choosing among a feed's tracks.
enum TranscriptParsing {
    // MARK: Choosing

    /// Readable tracks, best first: the user's language (then untagged, then others), then json > vtt > srt > html > text,
    /// then a plain transcript over a closed-caption track, then feed order.
    static func ranked(_ tracks: [FeedTranscriptTrack], language: String? = Locale.current.language.languageCode?.identifier)
        -> [(track: FeedTranscriptTrack, format: TranscriptFormat)] {
        let wanted = language.map(primaryLanguage)
        func languageScore(_ t: FeedTranscriptTrack) -> Int {
            guard let l = t.language.map(primaryLanguage), !l.isEmpty else { return 1 }
            return l == wanted ? 0 : 2
        }
        return tracks.enumerated().compactMap { i, t in
            TranscriptFormat.detect(type: t.type, url: t.url).map { (i, t, $0) }
        }
        .sorted { a, b in
            let ka = [languageScore(a.1), TranscriptFormat.allCases.firstIndex(of: a.2) ?? 9, a.1.rel?.lowercased() == "captions" ? 1 : 0, a.0]
            let kb = [languageScore(b.1), TranscriptFormat.allCases.firstIndex(of: b.2) ?? 9, b.1.rel?.lowercased() == "captions" ? 1 : 0, b.0]
            return ka.lexicographicallyPrecedes(kb)
        }
        .map { ($0.1, $0.2) }
    }

    /// "en-US" / "en_US" -> "en".
    static func primaryLanguage(_ code: String) -> String {
        code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    // MARK: Parsing

    static func segments(_ body: String, format: TranscriptFormat) -> [Transcript.Segment] {
        switch format.sniffed(body) {
        case .json: json(body)
        case .vtt, .srt: cues(body)
        case .html: html(body)
        case .text: plain(body)
        }
    }

    /// Podcast Index JSON: `{"segments":[{"startTime":…,"speaker":…,"body":…}]}` (also a bare array, `start`/`text` keys).
    static func json(_ body: String) -> [Transcript.Segment] {
        guard let data = body.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (root as? [String: Any])?["segments"] as? [[String: Any]] ?? root as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let text = clean((s["body"] ?? s["text"]) as? String ?? "") else { return nil }
            return Transcript.Segment(start: seconds(s["startTime"] ?? s["start"]), speaker: clean(s["speaker"] as? String ?? ""), text: text)
        }
    }

    /// WebVTT and SRT: blocks separated by blank lines, each with a `start --> end` line and the cue text after it.
    /// `<v Speaker>` voice tags give the speaker; other tags are stripped; NOTE/STYLE/REGION blocks and the header are skipped.
    static func cues(_ body: String) -> [Transcript.Segment] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var out: [Transcript.Segment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let head = lines[0]
            if head.hasPrefix("WEBVTT") || head.hasPrefix("NOTE") || head.hasPrefix("STYLE") || head.hasPrefix("REGION") { continue }
            let start = timestamp(String(lines[timing].split(separator: "-->")[0]))
            var raw = lines[(timing + 1)...].joined(separator: " ")
            let speaker = FeedParsingSupport.firstGroup(#"<v(?:\.[^\s>]*)?\s+([^>]+)>"#, in: raw)
            raw = raw.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\{\\an?\d\}"#, with: "", options: .regularExpression)
            guard let text = clean(FeedParsingSupport.decodeHTMLEntities(raw)) else { continue }
            out.append(Transcript.Segment(start: start, speaker: speaker.flatMap { clean(FeedParsingSupport.decodeHTMLEntities($0)) }, text: text))
        }
        return out
    }

    /// HTML: one segment per block element. A paragraph that opens with a bracketed or line-leading timestamp
    /// ("[00:12:03] …", "12:03 …") is timed; everything else is untimed.
    static func html(_ body: String) -> [Transcript.Segment] {
        var s = body.replacingOccurrences(of: #"<(script|style|head)[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>|</(p|div|li|h[1-6]|blockquote|tr)>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return paragraphs(FeedParsingSupport.decodeHTMLEntities(s)).compactMap { p in
            let lead = #"^[\[\(]?((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d+)?)[\]\)]?(?:\s*[-–—:]\s*|\s+)"#
            if let t = FeedParsingSupport.firstGroup(lead, in: p), let r = p.range(of: lead, options: .regularExpression),
               p.hasPrefix("[") || p.hasPrefix("(") || p.dropFirst(t.count).first?.isWhitespace == true,
               let text = clean(String(p[r.upperBound...])) {
                return Transcript.Segment(start: timestamp(t), text: text)
            }
            return clean(p).map { Transcript.Segment(start: nil, text: $0) }
        }
    }

    /// Plain text: one untimed segment per paragraph (per line when there are no blank lines).
    static func plain(_ body: String) -> [Transcript.Segment] {
        paragraphs(body).compactMap { clean($0) }.map { Transcript.Segment(start: nil, text: $0) }
    }

    // MARK: Helpers

    private static func paragraphs(_ text: String) -> [String] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = t.replacingOccurrences(of: #"\n[ \t]*\n\s*"#, with: "\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")
        let nonEmpty = blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if nonEmpty.count == 1 { return nonEmpty[0].split(separator: "\n").map(String.init) }
        return nonEmpty
    }

    /// Whitespace collapsed and trimmed; nil when nothing is left.
    static func clean(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "01:02:03.500", "02:03,500", "3.5" -> seconds.
    static func timestamp(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func seconds(_ v: Any?) -> TimeInterval? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? timestamp(s) }
        return nil
    }
}
