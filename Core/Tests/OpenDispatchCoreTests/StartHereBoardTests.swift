import Testing
@testable import OpenDispatchCore

@Suite("Start here board")
struct StartHereBoardTests {
    /// A board that came up on an empty library.
    private func upBoard() -> StartHereBoard {
        var board = StartHereBoard()
        board.libraryRead([])
        return board
    }

    @Test("Is down until the library has been read")
    func downBeforeTheFirstRead() {
        #expect(!StartHereBoard().isUp)
    }

    @Test("Comes up on an empty library and not on one with anything in it, as on a relaunch")
    func firstRead() {
        #expect(upBoard().isUp)
        var board = StartHereBoard()
        board.libraryRead([1, 2])
        #expect(!board.isUp)
    }

    @Test("Stays up as sources are added here, until dismissed")
    func staysUpWhileAdding() {
        var board = upBoard()
        board.willAdd()
        board.didAdd([1])
        board.libraryRead([1])
        #expect(board.isUp)
        board.dismiss()
        #expect(!board.isUp)
    }

    @Test("Sources arriving from iCloud take it down")
    func syncedSourcesTakeItDown() {
        var board = upBoard()
        board.libraryRead([7, 8])
        #expect(!board.isUp)
    }

    @Test("A synced source among ones added here takes it down too")
    func syncedSourceAfterAdding() {
        var board = upBoard()
        board.willAdd()
        board.didAdd([1])
        board.libraryRead([1])
        #expect(board.isUp)
        board.libraryRead([1, 9])
        #expect(!board.isUp)
    }

    @Test("A source read before its add reports it isn't taken for a synced one")
    func concurrentAdds() {
        var board = upBoard()
        board.willAdd()
        board.willAdd()
        // The first add's read finds the second's source already stored.
        board.didAdd([1])
        board.libraryRead([1, 2])
        #expect(board.isUp)
        board.didAdd([2])
        board.libraryRead([1, 2])
        #expect(board.isUp)
    }

    @Test("A synced source that lands during an add takes it down once the add ends")
    func syncedSourceDuringAdd() {
        var board = upBoard()
        board.willAdd()
        board.libraryRead([9])
        #expect(board.isUp)
        board.didAdd([1])
        #expect(!board.isUp)
    }

    @Test("A failed add leaves it up")
    func failedAdd() {
        var board = upBoard()
        board.willAdd()
        board.didAdd([])
        board.libraryRead([])
        #expect(board.isUp)
        #expect(board.isLibraryEmpty)
    }

    @Test("An empty library can't dismiss it")
    func dismissOnEmptyLibrary() {
        var board = upBoard()
        board.dismiss()
        #expect(board.isUp)
    }

    @Test("Removing what was added leaves it up")
    func removedWhileUp() {
        var board = upBoard()
        board.willAdd()
        board.didAdd([1, 2])
        board.libraryRead([1, 2])
        board.libraryRead([2])
        #expect(board.isUp)
        board.libraryRead([])
        #expect(board.isUp)
    }

    @Test("Comes back when the library is emptied later, and what was added before no longer counts")
    func emptiedLater() {
        var board = StartHereBoard()
        board.libraryRead([1, 2])
        board.willAdd()
        board.didAdd([3])
        board.libraryRead([1, 2, 3])
        #expect(!board.isUp)
        board.libraryRead([])
        #expect(board.isUp)
        // A later arrival with an id added before the board came up is still foreign.
        board.libraryRead([3])
        #expect(!board.isUp)
    }

    @Test("Done doesn't stick once the library empties")
    func dismissedThenEmptied() {
        var board = upBoard()
        board.willAdd()
        board.didAdd([1])
        board.libraryRead([1])
        board.dismiss()
        board.libraryRead([])
        #expect(board.isUp)
    }
}

@Suite("Starter pack progress")
struct StarterPackProgressTests {
    private let pack = StarterPack(name: "News", sources: [
        StarterSource(title: "One", host: "one.example", feedUrl: "https://one.example/rss"),
        StarterSource(title: "Two", host: "two.example", feedUrl: "https://two.example/rss"),
        StarterSource(title: "Three", host: "three.example", feedUrl: "https://three.example/rss"),
    ])

    private func progress(_ steps: StarterPackProgress.Step...) -> StarterPackProgress {
        var remaining = steps
        return StarterPackProgress(pack) { _ in remaining.removeFirst() }
    }

    @Test("Nothing started offers Add")
    func idle() {
        let p = progress(.idle, .idle, .idle)
        #expect(!p.isAdding)
        #expect(!p.isAdded)
        #expect(p.failureNote == nil)
    }

    @Test("Any source still adding keeps the spinner, whatever the others did")
    func adding() {
        #expect(progress(.adding, .added, .failed).isAdding)
        #expect(!progress(.adding, .added, .added).isAdded)
    }

    @Test("All added reads Added")
    func added() {
        #expect(progress(.added, .added, .added).isAdded)
    }

    @Test("A failure doesn't block the others, and is noted")
    func someFailed() {
        let p = progress(.added, .failed, .added)
        #expect(p.isAdded)
        #expect(p.failureNote == "Couldn\u{2019}t add Two")
    }

    @Test("All failed offers Add again and names them")
    func allFailed() {
        let p = progress(.failed, .failed, .failed)
        #expect(!p.isAdded)
        #expect(p.failureNote == "Couldn\u{2019}t add One, Two, Three")
    }

    @Test("A source removed since, or never started, offers Add for the rest")
    func someIdle() {
        #expect(!progress(.added, .idle, .added).isAdded)
    }
}
