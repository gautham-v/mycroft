import Foundation
import Observation
import OpenDispatchCore

/// Read state and History: every row of the history table, kept current by observing the database (so
/// what another device read shows up too), and the writes that change it. AppModel owns it (`model.history`)
/// and records what the reader opens; rows, menus, the players and the History view read and write here.
@MainActor
@Observable
final class HistoryStore {
    /// Every row, the most recently opened or marked read first.
    private(set) var entries: [HistoryEntry] = []
    /// `entries` by article key (Highlight.articleKey), for the list rows.
    private var byKey: [String: HistoryEntry] = [:]

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// When each article's playback position was last written, so a playing video writes every few seconds
    /// rather than every second.
    @ObservationIgnored private var lastProgressWrite: [String: Date] = [:]

    /// How often a position is written while playing; pausing, seeking and leaving write at once.
    private static let progressInterval: TimeInterval = 10

    init(database: AppDatabase) {
        self.database = database
        observation = Task { [weak self, database] in
            do {
                for try await entries in database.observeHistory() {
                    self?.apply(entries)
                }
            } catch {
                // The lists keep what they had.
            }
        }
    }

    private func apply(_ entries: [HistoryEntry]) {
        self.entries = entries
        byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Reading

    /// What History lists: the articles opened, newest first (rows only marked read are left out).
    var opened: [HistoryEntry] { entries.filter { $0.openedAt != nil } }

    nonisolated static func key(for item: FeedItem) -> String {
        Highlight.articleKey(sourceFeedUrl: item.source.feedUrl, itemGuid: item.item.guid)
    }

    func entry(for item: FeedItem) -> HistoryEntry? { byKey[Self.key(for: item)] }

    func isRead(_ item: FeedItem) -> Bool { entry(for: item)?.isRead ?? false }

    /// How far into a video or episode while it's in progress, else nil.
    func progress(_ item: FeedItem) -> Double? { entry(for: item)?.progress }

    /// Where to start a video or episode again: the saved position, unless it was finished.
    func resumePosition(_ item: FeedItem) -> Double? {
        guard let e = entry(for: item), e.progress != nil, let p = e.positionSec, p > 5 else { return nil }
        return p
    }

    // MARK: Writing

    /// The reader showed the item: it tops History, and an article is read.
    func recordOpen(_ item: FeedItem) {
        let snapshot = HistoryEntry(item: item), media = HistoryEntry.isMedia(item)
        Task { try? await database.recordOpen(snapshot, isMedia: media) }
    }

    func setRead(_ item: FeedItem, _ read: Bool) {
        let snapshot = HistoryEntry(item: item)
        Task { try? await database.setRead(snapshot, read: read) }
    }

    func toggleRead(_ item: FeedItem) { setRead(item, !isRead(item)) }

    /// A History row's Mark as Read / Unread, for an article that may no longer be in any list.
    func setRead(_ entry: HistoryEntry, _ read: Bool) {
        Task { try? await database.setRead(entry, read: read) }
    }

    /// Playback reached `position` of `duration` seconds (0 when unknown). Written every few seconds while
    /// playing; `force` writes now (pause, seek, leaving the reader, the end).
    func recordProgress(_ item: FeedItem, position: Double, duration: Double, force: Bool = false) {
        guard position.isFinite, duration.isFinite, position > 0 else { return }
        let key = Self.key(for: item), now = Date()
        let finishing = duration > 0 && position >= duration * HistoryEntry.finishedFraction && !isRead(item)
        if !force, !finishing, let last = lastProgressWrite[key], now.timeIntervalSince(last) < Self.progressInterval { return }
        lastProgressWrite[key] = now
        let snapshot = HistoryEntry(item: item)
        Task { try? await database.recordProgress(snapshot, position: position, duration: duration) }
    }

    /// "Mark as Read", or Watched / Played for a video or episode; the Un- form when it already is.
    nonisolated static func markLabel(kind: SourceKind, isRead: Bool) -> String {
        let word = switch kind {
        case .youtube: "Watched"
        case .podcast: "Played"
        default: "Read"
        }
        return "Mark as " + (isRead ? "Un" + word.lowercased() : word)
    }

    func remove(_ entry: HistoryEntry) {
        Task { try? await database.removeHistory(sourceFeedUrl: entry.sourceFeedUrl, itemGuid: entry.itemGuid) }
    }

    func clear(_ range: HistoryClearRange) {
        let since = range.since(now: Date())
        Task { try? await database.clearHistory(since: since) }
    }
}

/// Clear History's choices (Safari's): what was opened or marked read in the last hour, today, today and
/// yesterday, or everything.
enum HistoryClearRange: CaseIterable, Identifiable {
    case lastHour, today, todayAndYesterday, all

    var id: Self { self }

    var label: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    /// The start of the range; nil = everything.
    func since(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: nil
        }
    }
}
