import Foundation

/// Whether the "Start here" board is up. New installs start empty (`Seed`), so the board shows while the library
/// (sources and topics, by id) has nothing in it. It stays up as things are added on this device, so more can be added, until
/// it is dismissed; it isn't stored, so a relaunch with anything in the library doesn't bring it back. Something in the library
/// that wasn't added here came from iCloud: that library takes over and the board goes away.
public struct StartHereBoard: Sendable, Equatable {
    public private(set) var isUp = false
    public var isLibraryEmpty: Bool { library.isEmpty }

    private var library: Set<Int64> = []
    /// What was added on this device since the board last came up.
    private var added: Set<Int64> = []
    /// Adds under way. What they store can be read before they report it, so nothing is judged until they end.
    private var addsRunning = 0

    public init() {}

    /// The library as just read.
    public mutating func libraryRead(_ ids: Set<Int64>) {
        library = ids
        settle()
    }

    public mutating func willAdd() {
        addsRunning += 1
    }

    /// An add ended, having stored `ids` (none when it failed).
    public mutating func didAdd(_ ids: Set<Int64>) {
        addsRunning = max(addsRunning - 1, 0)
        added.formUnion(ids)
        settle()
    }

    /// Done, or an article opened. An empty library keeps the board: there is nothing else to show.
    public mutating func dismiss() {
        if !library.isEmpty { isUp = false }
    }

    private mutating func settle() {
        if library.isEmpty {
            if !isUp, addsRunning == 0 { added = [] }
            isUp = true
        } else if isUp, addsRunning == 0, !library.isSubset(of: added) {
            isUp = false
        }
    }
}

/// What a starter pack's row on the board shows, from where each of its sources stands. A failed source doesn't hold up the
/// others: the pack reads as added once they have all ended and one made it, with the failures in a note.
public struct StarterPackProgress: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case idle, adding, added, failed
    }

    public let isAdding: Bool
    public let isAdded: Bool
    public let failedTitles: [String]

    public init(_ pack: StarterPack, step: (StarterSource) -> Step) {
        let steps = pack.sources.map { (source: $0, step: step($0)) }
        isAdding = steps.contains { $0.step == .adding }
        isAdded = !isAdding && steps.contains { $0.step == .added } && !steps.contains { $0.step == .idle }
        failedTitles = steps.filter { $0.step == .failed }.map(\.source.title)
    }

    /// The muted line under the row; nil when nothing failed.
    public var failureNote: String? {
        failedTitles.isEmpty ? nil : "Couldn\u{2019}t add " + failedTitles.joined(separator: ", ")
    }
}
