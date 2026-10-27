import Foundation

/// What Copy as Markdown put together: the text for the clipboard plus what the confirmation shows.
public struct CopiedText: Sendable, Hashable {
    public var markdown: String
    /// Words in the copied body (prompt and header lines excluded), for "Copied · 2,340 words".
    public var wordCount: Int
    /// 1 for an item; the number of items for a digest.
    public var itemCount: Int
    /// Set when something expected was missing, e.g. "No transcript, so this has the show notes."
    public var note: String?

    public init(markdown: String, wordCount: Int, itemCount: Int, note: String? = nil) {
        self.markdown = markdown
        self.wordCount = wordCount
        self.itemCount = itemCount
        self.note = note
    }
}

/// Copy as Markdown: one item's full text or transcript, or a digest of a view/folder/source's recent items,
/// as Markdown to paste into an AI or anywhere else. Owner: Export.
public struct CopyService: Sendable {
    public let database: AppDatabase
    public let content: ContentService
    public let transcripts: any TranscriptFetching
    /// Time zone for the dates in the text. Tests pin it.
    var timeZone: TimeZone = .current

    public init(database: AppDatabase, content: ContentService, transcripts: any TranscriptFetching) {
        self.database = database
        self.content = content
        self.transcripts = transcripts
    }

    /// One item. Articles: the cached (or freshly extracted) text. Videos: description + transcript.
    /// Podcasts (and posts with an audio episode, like Substack podcasts): show notes + transcript. A non-empty `prompt` goes first, followed by a `---` rule.
    /// Throws QueryError.notFound for an unknown id; extraction errors propagate.
    public func markdown(forItem id: Int64, prompt: String? = nil) async throws -> CopiedText {
        let pair = try await database.reader.read { db -> (Item, Source)? in
            guard let item = try Queries.itemRecord(db, id: id), let src = try Queries.source(db, id: item.sourceId) else { return nil }
            return (item, src.shown(for: item))
        }
        guard let (item, source) = pair else { throw QueryError.notFound("Item") }
        let isVideo = source.kind == .youtube
        // A blog post with an audio enclosure is an episode too (Substack podcasts): show notes + transcript.
        let isMedia = isVideo || source.kind == .podcast || item.audioUrl != nil

        async let html = articleHTML(id, source, isMedia: isMedia)
        async let transcript = isMedia ? fetchTranscript(item, source) : nil
        let extracted = try await html
        let spoken = await transcript

        let summary = (item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func summaryMarkdown() -> String { summary.isEmpty ? "" : MarkdownConverter.convertSummary(summary, baseURL: item.url) }

        var sections: [String] = []
        var words = 0
        var note: String?
        if !isMedia {
            var body = extracted.map { MarkdownConverter.convert($0, baseURL: item.url) } ?? ""
            if body.isEmpty {
                body = summaryMarkdown()
                note = body.isEmpty ? "No text was available for this item." : "Couldn't extract the full text, so this has the feed summary."
            }
            if !body.isEmpty { sections.append(body) }
            words += MarkdownConverter.wordCount(body)
        } else {
            let label = isVideo ? "description" : "show notes"
            var body = isVideo ? summaryMarkdown() : (extracted.map { MarkdownConverter.convert($0, baseURL: item.url) } ?? "")
            if body.isEmpty { body = summaryMarkdown() }
            if !body.isEmpty {
                sections.append("## " + (isVideo ? "Description" : "Show notes") + "\n\n" + body)
                words += MarkdownConverter.wordCount(body)
            }
            if let spoken, !spoken.segments.isEmpty {
                let text = ItemMarkdown.transcriptText(spoken, long: ItemMarkdown.isLong(spoken, durationSec: item.durationSec))
                sections.append("## Transcript (\(spoken.origin.label))\n\n" + text)
                words += ItemMarkdown.wordCount(spoken)
            } else {
                note = "No transcript, so this has the \(label)."
            }
        }

        let document = ([ItemMarkdown.header(item: item, source: source, timeZone: timeZone)] + sections).joined(separator: "\n\n")
        return CopiedText(markdown: ItemMarkdown.withPrompt(document, prompt), wordCount: words, itemCount: 1, note: note)
    }

    /// Items matching `query` (its view/source/folder; cursor and search ignored) published since `since`,
    /// newest first, at most 200: title, source, time, link and a short summary each, not full text.
    /// `title` names the scope in the heading ("News", "All", "Simon Willison").
    public func digest(_ query: ItemQuery, title: String, since: Date, now: Date = Date(), prompt: String? = nil) async throws -> CopiedText {
        var q = query
        q.since = since
        q.cursor = nil
        q.search = ""
        q.limit = ItemMarkdown.digestCap
        let items = try await database.items(q).items
        let out = ItemMarkdown.digest(items, title: title, since: since, now: now, capped: items.count >= ItemMarkdown.digestCap, timeZone: timeZone)
        return CopiedText(markdown: ItemMarkdown.withPrompt(out.markdown, prompt), wordCount: out.words, itemCount: items.count)
    }

    /// The item's article (or show notes) HTML. An episode whose notes can't be fetched falls back to the feed summary.
    private func articleHTML(_ id: Int64, _ source: Source, isMedia: Bool) async throws -> String? {
        do {
            return try await content.content(forItem: id).contentHtml
        } catch where isMedia && source.kind != .youtube {
            return nil
        }
    }

    /// nil when there is no transcript or fetching it failed: the copy goes ahead without one.
    private func fetchTranscript(_ item: Item, _ source: Source) async -> Transcript? {
        try? await transcripts.transcript(for: item, source: source)
    }
}
