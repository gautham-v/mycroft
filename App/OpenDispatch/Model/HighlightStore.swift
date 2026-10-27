import Foundation
import GRDB
import Observation
import OpenDispatchCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A passage selected in the article: its text and the text around it (the anchor stored with a highlight).
struct HighlightAnchor: Equatable, Sendable {
    var text: String
    var prefix: String
    var suffix: String
}

/// Highlights and notes: the list of every highlight (kept current by observing the database, so
/// iCloud changes and Readwise ids show up too), what the reader's popover and sheets are showing, and the
/// edits the reader makes. A store of its own, injected through the environment, so AppModel stays about
/// feeds. Edits go to the database and come back through the observation.
@MainActor
@Observable
final class HighlightStore {
    /// Where a highlight sits in the open article, reported by the page after it resolves them.
    struct Resolution: Equatable {
        /// Highlight ids found in the article, in document order.
        var order: [String] = []
        /// Ids the page could not find in this version of the article.
        var missing: Set<String> = []
    }

    /// A request to bring a highlight into view in a reader pane. The page answers with `ready`.
    struct ScrollRequest: Equatable {
        var id: String
        var pane: Int
        var nonce: Int
    }

    /// A highlight clicked in the article, for the popover under it. `rect` is where the page drew the
    /// clicked line (or the note marker's line), in the web view's own coordinates.
    struct Popover: Equatable {
        var id: String
        var pane: Int
        var rect: CGRect
    }

    /// A highlight whose note the note sheet is editing, in the pane that asked.
    struct NoteRequest: Equatable, Identifiable {
        var id: String
        var pane: Int
    }

    enum ReadwiseState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// Every highlight by article, the article with the newest activity first.
    private(set) var groups: [HighlightGroup] = []
    private(set) var resolutions: [String: Resolution] = [:]
    /// iPhone: the Highlights & Notes list sheet is up (the Mac and iPad list is a popover of its button).
    var isSheetPresented = false
    /// The popover under a clicked highlight; nil when none is open.
    private(set) var popover: Popover?
    /// The note sheet's highlight; nil when it is closed.
    var noteRequest: NoteRequest?
    private(set) var scrollRequest: ScrollRequest?
    /// The page has put the scroll marker at the highlight; the reader may scroll to it.
    private(set) var scrollReady: ScrollRequest?
    private(set) var readwiseState: ReadwiseState = .idle
    private(set) var readwiseLastSent: Date?
    private(set) var readwisePending = 0

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let readwise: ReadwiseHighlightSync
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var nonce = 0
    @ObservationIgnored private var readwiseWasOn = false
    /// `groups` by article, so a reader looks its highlights up without scanning (observed with `groups`).
    private var byArticle: [String: [Highlight]] = [:]

    init(model: AppModel) {
        self.model = model
        readwise = ReadwiseHighlightSync(database: model.database)
        observation = Task { [weak self, database = model.database] in
            do {
                for try await groups in database.observeHighlightGroups() {
                    self?.apply(groups)
                }
            } catch {
                // The lists keep what they had.
            }
        }
        watchReadwiseSettings()
        // Whatever an earlier run left unsent goes out now.
        kickReadwise()
    }

    private func apply(_ groups: [HighlightGroup]) {
        self.groups = groups
        byArticle = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.highlights) })
    }

    // MARK: Reading

    var count: Int { groups.reduce(0) { $0 + $1.count } }

    nonisolated static func key(for item: FeedItem) -> String {
        Highlight.articleKey(sourceFeedUrl: item.source.feedUrl, itemGuid: item.item.guid)
    }

    /// An article's highlights in the order they were made.
    func highlights(forKey key: String) -> [Highlight] { byArticle[key] ?? [] }

    func highlight(id: String) -> Highlight? {
        groups.lazy.flatMap(\.highlights).first { $0.id == id }
    }

    /// In document order once the page has reported where they are; ones it couldn't find come last.
    func ordered(forKey key: String) -> [Highlight] {
        let all = highlights(forKey: key)
        guard let order = resolutions[key]?.order else { return all }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return all.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    func resolution(forKey key: String) -> Resolution? { resolutions[key] }

    func setResolution(_ r: Resolution, forKey key: String) {
        if resolutions[key] != r { resolutions[key] = r }
    }

    // MARK: Popover and note sheet

    /// A click on a highlight (or its note marker) in the article: its popover opens under `rect`.
    func showPopover(_ id: String, rect: CGRect, pane: Int) {
        popover = Popover(id: id, pane: pane, rect: rect)
    }

    func closePopover() {
        if popover != nil { popover = nil }
    }

    /// Opens the note sheet on a highlight (Add Note…, Edit Note…, the popover's note). A popover that is
    /// still up closes first and the sheet follows a moment later: presenting a sheet from under a
    /// dismissing popover is dropped. A highlight just made reaches `groups` through the database
    /// observation a moment after it is inserted, so the sheet waits for it.
    func editNote(_ id: String, pane: Int) {
        let hadPopover = popover != nil
        closePopover()
        Task { [weak self] in
            if hadPopover { try? await Task.sleep(for: .milliseconds(200)) }
            var polls = 0
            while let self, self.highlight(id: id) == nil, polls < 40 {
                try? await Task.sleep(for: .milliseconds(25))
                polls += 1
            }
            self?.noteRequest = NoteRequest(id: id, pane: pane)
        }
    }

    /// The list asks the reader to scroll to a highlight.
    func scroll(to id: String, pane: Int) {
        nonce += 1
        scrollRequest = ScrollRequest(id: id, pane: pane, nonce: nonce)
    }

    func scrollIsReady(_ request: ScrollRequest) { scrollReady = request }

    // MARK: Editing

    /// Whether changes made now should be sent to Readwise.
    private var sendsToReadwise: Bool {
        model.settings.sendHighlightsToReadwise && model.integrations.readwiseConfigured
    }

    /// Highlight `anchor` in `item`'s article. Returns the new highlight.
    @discardableResult
    func add(_ anchor: HighlightAnchor, in item: FeedItem, color: HighlightColor, note: String = "") async -> Highlight? {
        guard !anchor.text.isEmpty else { return nil }
        let h = Highlight(
            sourceFeedUrl: item.source.feedUrl, itemGuid: item.item.guid, itemUrl: item.item.url,
            itemTitle: item.item.title, sourceTitle: item.source.title, itemAuthor: item.item.author,
            itemPublishedAt: item.item.publishedAt, text: anchor.text, prefix: anchor.prefix, suffix: anchor.suffix,
            note: note, color: color)
        guard (try? await model.database.insertHighlight(h, forReadwise: sendsToReadwise)) != nil else { return nil }
        kickReadwise()
        return h
    }

    func setColor(_ id: String, _ color: HighlightColor) {
        let forReadwise = sendsToReadwise
        Task {
            _ = try? await model.database.updateHighlight(id: id, color: color, forReadwise: forReadwise)
            kickReadwise()
        }
    }

    func setNote(_ id: String, _ note: String) {
        let forReadwise = sendsToReadwise
        Task {
            _ = try? await model.database.updateHighlight(id: id, note: note, forReadwise: forReadwise)
            kickReadwise()
        }
    }

    func remove(_ id: String) {
        let forReadwise = sendsToReadwise
        Task {
            _ = try? await model.database.deleteHighlight(id: id, forReadwise: forReadwise)
            kickReadwise()
        }
    }

    // MARK: Opening an article from the Highlights view

    /// Opens the article a group of highlights came from in the reader. The item is added from the highlights' own data when only its source is here; when the source is
    /// gone too, the original URL opens in the browser.
    func open(_ group: HighlightGroup, inNewTab: Bool = false) async {
        guard let item = try? await model.database.itemForHighlights(sourceFeedUrl: group.sourceFeedUrl, itemGuid: group.itemGuid) else {
            if let url = URL(string: group.itemUrl) { ReaderWebSupport.openExternally(url) }
            return
        }
        if inNewTab { model.openInNewTab(item) } else { model.open(item) }
    }

    // MARK: Markdown

    /// An article's highlights and notes as Markdown: the title as a heading, then each quote as a block
    /// quote followed by its note.
    func markdown(forKey key: String) -> String {
        let list = ordered(forKey: key)
        guard let first = list.first else { return "" }
        var out = "# \(first.itemTitle)\n\n"
        var byline = [first.sourceTitle]
        if let author = first.itemAuthor, !author.isEmpty, author != first.sourceTitle { byline.append(author) }
        out += byline.joined(separator: " \u{00B7} ") + "\n\(first.itemUrl)\n"
        for h in list {
            out += "\n" + h.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n"
            if !h.note.isEmpty { out += "\n\(h.note)\n" }
        }
        return out
    }

    func copyMarkdown(forKey key: String) {
        let text = markdown(forKey: key)
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: Readwise

    /// "Send highlights to Readwise" is on and a token is set.
    var readwiseOn: Bool { sendsToReadwise }

    /// The list footer's line, nil when Readwise is off.
    var readwiseLine: String? {
        guard readwiseOn else { return nil }
        switch readwiseState {
        case .sending: return "Sending to Readwise\u{2026}"
        case .failed(let message): return "Readwise: \(message). Will retry on the next change."
        case .idle:
            if readwisePending > 0 { return "\(readwisePending) waiting to send to Readwise" }
            guard let at = readwiseLastSent else { return "Highlights are sent to Readwise" }
            let age = RelativeTime.format(at)
            return age == "now" ? "Sent to Readwise just now" : "Sent to Readwise \(age) ago"
        }
    }

    /// Sends whatever is queued, in the background. A failure leaves it queued for the next change or launch.
    func kickReadwise() {
        Task {
            guard model.settings.sendHighlightsToReadwise,
                  (try? await model.services.integrations.state().readwiseConfigured) == true else { return }
            readwiseState = .sending
            let outcome = await readwise.send()
            readwisePending = outcome.remaining
            if let error = outcome.error {
                readwiseState = .failed(error)
            } else {
                readwiseState = .idle
                if outcome.sent + outcome.deleted > 0 { readwiseLastSent = Date() }
            }
        }
    }

    /// Sends what is queued when the toggle or the token turns sending on.
    private func watchReadwiseSettings() {
        withObservationTracking {
            _ = model.settings
            _ = model.integrations
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let on = self.readwiseOn
                if on && !self.readwiseWasOn { self.kickReadwise() }
                self.readwiseWasOn = on
                self.watchReadwiseSettings()
            }
        }
    }
}
