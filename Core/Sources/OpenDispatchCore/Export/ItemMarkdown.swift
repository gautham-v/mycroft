import Foundation

/// Composes the Markdown documents Copy as Markdown puts on the clipboard.
enum ItemMarkdown {
    // MARK: Item

    /// The title, meta line, link(s), as the top of an item document.
    static func header(item: Item, source: Source, timeZone: TimeZone) -> String {
        let title = oneLine(item.title)
        var meta: [String] = []
        switch source.kind {
        case .youtube:
            meta = [source.title, "YouTube", longDate(item.publishedAt, timeZone)]
        case .podcast:
            meta = [source.title, longDate(item.publishedAt, timeZone)]
        case .rss, .page:
            let author = oneLine(item.author ?? "")
            if !author.isEmpty, author.caseInsensitiveCompare(source.title) != .orderedSame { meta.append(author) }
            meta.append(contentsOf: [source.title, longDate(item.publishedAt, timeZone)])
        }
        if source.kind != .rss, source.kind != .page, let d = TextFormat.duration(item.durationSec) { meta.append(d) }
        var lines = ["# " + (title.isEmpty ? "Untitled" : title), meta.joined(separator: " · "), item.url]
        if let discussion = item.hnCommentsUrl, !discussion.isEmpty { lines.append("Discussion: " + discussion) }
        return lines.joined(separator: "\n")
    }

    /// `prompt`, a rule, then `document`; the document alone when the prompt is blank.
    static func withPrompt(_ document: String, _ prompt: String?) -> String {
        let p = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? document : p + "\n\n---\n\n" + document
    }

    /// Transcript text as timestamped lines: caption cues grouped into lines of roughly 20 to 40 seconds,
    /// a new line when the speaker changes. Untimed segments become plain paragraphs.
    /// `long`: use `h:mm:ss` timestamps.
    static func transcriptText(_ transcript: Transcript, long: Bool) -> String {
        transcript.paragraphs.map { line in
            var out = ""
            if let start = line.start { out += "[" + timestamp(start, long: long) + "] " }
            if let speaker = line.speaker { out += MarkdownConverter.escape(speaker) + ": " }
            let text = MarkdownConverter.escape(line.text)
            return out.isEmpty ? MarkdownConverter.escapeLineStart(text) : out + text
        }.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: TimeInterval, long: Bool) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return long ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", h * 60 + m, sec)
    }

    /// True when `h:mm:ss` timestamps are needed: the episode runs over an hour.
    static func isLong(_ transcript: Transcript, durationSec: Int?) -> Bool {
        if let d = durationSec, d > 3600 { return true }
        return (transcript.segments.compactMap(\.start).max() ?? 0) >= 3600
    }

    static func wordCount(_ transcript: Transcript) -> Int {
        transcript.segments.reduce(0) { $0 + MarkdownConverter.wordCount($1.text) }
    }

    // MARK: Digest

    static let digestCap = 200

    static func digest(_ items: [FeedItem], title: String, since: Date, now: Date, capped: Bool, timeZone: TimeZone) -> (markdown: String, words: Int) {
        let span = now.timeIntervalSince(since)
        let hour: TimeInterval = 3600
        let range: String
        if abs(span - 24 * hour) <= hour { range = "last 24 hours" }
        else if abs(span - 7 * 24 * hour) <= hour { range = "last 7 days" }
        else { range = "since " + longDate(since, timeZone) }

        let count = items.count == 1 ? "1 item" : (capped ? "newest \(items.count) items" : "\(items.count) items")
        var out = ["# \(oneLine(title)) · \(range)\n\(count) · copied \(longDate(now, timeZone)) at \(clock(now, timeZone))"]
        var words = 0
        if items.isEmpty {
            out.append("No items in this period.")
        }
        for feedItem in items {
            let item = feedItem.item
            let heading = oneLine(item.title)
            var block = "## " + (heading.isEmpty ? "Untitled" : heading)
            block += "\n" + [feedItem.source.title, shortDateTime(item.publishedAt, now: now, timeZone), item.url].joined(separator: " · ")
            let summary = truncate(MarkdownConverter.plainText(fromHTML: item.summary ?? ""), to: 280)
            if !summary.isEmpty {
                words += MarkdownConverter.wordCount(summary)
                block += "\n" + MarkdownConverter.escapeLineStart(MarkdownConverter.escape(summary))
            }
            out.append(block)
        }
        return (out.joined(separator: "\n\n"), words)
    }

    /// `text` cut at a word boundary to about `limit` characters, with an ellipsis when cut.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if text[text.index(text.startIndex, offsetBy: limit)] != " ", let space = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last == " " || ",;:-–—".contains(last) { cut.removeLast() }
        return cut + "…"
    }

    // MARK: Text

    static func oneLine(_ s: String) -> String {
        MarkdownConverter.collapse(s).trimmingCharacters(in: .whitespaces)
    }

    private static let locale = Locale(identifier: "en_US")
    private static let calendar = Calendar(identifier: .gregorian)

    private static func style(_ tz: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: tz)
    }

    /// "October 27, 2026".
    static func longDate(_ date: Date, _ tz: TimeZone) -> String {
        date.formatted(style(tz).month(.wide).day().year())
    }

    /// "8:04 AM".
    static func clock(_ date: Date, _ tz: TimeZone) -> String {
        date.formatted(style(tz).hour().minute())
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{A0}", with: " ")
    }

    /// "Oct 27, 8:04 AM", with the year when it isn't `now`'s.
    static func shortDateTime(_ date: Date, now: Date, _ tz: TimeZone) -> String {
        var cal = calendar
        cal.timeZone = tz
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let day = sameYear ? date.formatted(style(tz).month(.abbreviated).day()) : date.formatted(style(tz).month(.abbreviated).day().year())
        return day + ", " + clock(date, tz)
    }
}
