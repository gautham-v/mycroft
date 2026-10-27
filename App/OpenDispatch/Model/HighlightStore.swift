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
/// iCloud changes and Readwise ids show up too), what the reader's panel and sheet are doing, and the
/// edits the reader and the panel make. A store of its own, injected through the environment, so AppModel
/// stays about feeds. Edits go to the database and come back through the observation.
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

    enum ReadwiseState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// Every highlight by article, the article with the newest activity first.
    private(set) var groups: [HighlightGroup] = []
    private(set) var resolutions: [String: Resolution] = [:]
    /// Mac: the reader panes whose Highlights & Notes panel is open.
    private(set) var openPanes: Set<Int> = []
    /// iPhone: the Highlights sheet is up.
    var isSheetPresented = false
    /// The highlight whose note field takes focus (Add Note…, Edit Note…).
    var focusNote: String?
    /// The panel's entry to point out after a click on the highlight in the article.
    private(set) var selected: String?
    /// iPhone: the highlight the tap menu (change color, edit note, remove) is about.
    var actionTarget: String?
    private(set) var scrollRequest: ScrollRequest?
    /// The page has put the scroll marker at the highlight; the reader may scroll to it.
    private(set) var scrollReady: ScrollRequest?
    private(set) var readwiseState: ReadwiseState = .idle
    private(set) var readwiseLastSent: Date?
    private(set) var readwisePending = 0

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let readwise: ReadwiseHighlightSync
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var selectedReset: Task<Void, Never>?
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
                // The panel and list keep what they had.
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

    // MARK: Panel

    func isPanelOpen(pane: Int) -> Bool { openPanes.contains(pane) }

    func setPanel(pane: Int, open: Bool) {
        if open { openPanes.insert(pane) } else { openPanes.remove(pane) }
    }

    func togglePanel(pane: Int) { setPanel(pane: pane, open: !isPanelOpen(pane: pane)) }

    /// Shows the panel in a pane, or the sheet on iPhone (`compact`).
    func showPanel(pane: Int, compact: Bool) {
        if compact { isSheetPresented = true } else { setPanel(pane: pane, open: true) }
    }

    /// A click on a highlight in the article: the panel opens at its entry; on iPhone a menu offers what to
    /// do with it.
    func tapped(_ id: String, pane: Int, compact: Bool) {
        if compact {
            actionTarget = id
        } else {
            setPanel(pane: pane, open: true)
            point(at: id)
        }
    }

    /// Marks an entry for a moment and has the panel scroll to it.
    func point(at id: String) {
        selected = id
        selectedReset?.cancel()
        selectedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.selected = nil }
        }
    }

    /// The panel or sheet asks the reader to scroll to a highlight.
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

    /// Opens the article a group of highlights came from in the reader, with the panel open on the Mac.
    /// The item is added from the highlights' own data when only its source is here; when the source is
    /// gone too, the original URL opens in the browser.
    func open(_ group: HighlightGroup, inNewTab: Bool = false) async {
        guard let item = try? await model.database.itemForHighlights(sourceFeedUrl: group.sourceFeedUrl, itemGuid: group.itemGuid) else {
            if let url = URL(string: group.itemUrl) { ReaderWebSupport.openExternally(url) }
            return
        }
        if inNewTab { model.openInNewTab(item) } else { model.open(item) }
        #if os(macOS)
        setPanel(pane: model.focusedPane, open: true)
        #endif
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

    /// The panel footer's line, nil when Readwise is off.
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
