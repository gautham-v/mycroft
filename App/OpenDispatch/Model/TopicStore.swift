import Foundation
import Observation
import OpenDispatchCore

/// What the Topic sheet is for: a new topic (starting from these options) or an existing one.
enum TopicEditorRequest: Identifiable {
    case new(TopicOptions)
    case edit(Source)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let topic): "edit-\(topic.id)"
        }
    }
}

/// The topics, kept current by observing the database (so a topic another device
/// made or edited shows up too). AppModel owns it (`model.topicStore`); the sidebar, the topic list's
/// header and Explore's Follow button read it. A topic is a source row, so the list of items, refresh and
/// notifications go through the same AppModel paths as any source; this holds only what the sources
/// list (which leaves topics out) can't give.
@MainActor
@Observable
final class TopicStore {
    /// In sidebar order.
    private(set) var topics: [Source] = []
    /// Ids of `topics`, changing only when a topic is added or removed, so views that need to know whether
    /// the selected source is a topic don't redraw on every refresh stamp.
    private(set) var ids: Set<Int64> = []
    /// Topics being searched now, for a spinner.
    private(set) var refreshing: Set<Int64> = []
    /// How many rows each filter of the open topic lists (a story is one row), for its title menu. Empty until the
    /// first count arrives and while no topic is open.
    private(set) var filterCounts: [TopicContentFilter: Int] = [:]

    /// A topic was added or removed.
    @ObservationIgnored var onIDsChange: () -> Void = {}
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private var observations: [Task<Void, Never>] = []
    @ObservationIgnored private var countsTopic: Int64?
    @ObservationIgnored private var countsObservation: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
        observations = [
            Task { [weak self, database] in
                do {
                    for try await topics in database.observeTopics() { self?.apply(topics) }
                } catch {
                    // The list keeps what it had.
                }
            },
        ]
    }

    /// Follows the filter counts of the open topic (nil: none is open). Called as the list moves.
    func watchFilterCounts(of id: Int64?) {
        guard id != countsTopic else { return }
        countsTopic = id
        countsObservation?.cancel()
        countsObservation = nil
        filterCounts = [:]
        guard let id else { return }
        countsObservation = Task { [weak self, database] in
            do {
                for try await counts in database.observeTopicFilterCounts(topicId: id) {
                    guard let self, self.countsTopic == id else { return }
                    self.filterCounts = counts
                }
            } catch {
                // The menu shows the filters without counts.
            }
        }
    }

    private func apply(_ topics: [Source]) {
        self.topics = topics
        let ids = Set(topics.map(\.id))
        if ids != self.ids {
            self.ids = ids
            onIDsChange()
        }
    }

    /// Reads the topics now, for a caller that just changed them and needs the result before the observation lands.
    func reload() async {
        if let topics = try? await database.topics() { apply(topics) }
    }

    /// Shows the topics in this order (top to bottom) before the database write lands, so a drag doesn't snap back.
    func applyOrder(_ order: [Int64]) {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var next = topics
        for i in next.indices { if let r = rank[next[i].id] { next[i].position = r } }
        topics = next.sorted { (rank[$0.id] ?? Int.max, $0.id) < (rank[$1.id] ?? Int.max, $1.id) }
    }

    func topic(id: Int64) -> Source? { topics.first { $0.id == id } }

    /// The topic whose keyword is `text`, ignoring case, diacritics and extra spaces (Explore's Following state).
    func topic(matching text: String) -> Source? {
        let wanted = Self.key(text)
        guard !wanted.isEmpty else { return nil }
        return topics.first { Self.key($0.topicKeyword ?? $0.title) == wanted }
    }

    private static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func setRefreshing(_ id: Int64, _ on: Bool) {
        if on { refreshing.insert(id) } else { refreshing.remove(id) }
    }
}
