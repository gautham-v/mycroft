import Foundation
import Observation
import OpenDispatchCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One reader tab. `itemID` nil follows the list's first item (the desktop default selection), unless
/// the tab is a new, empty one (`isNew`, from + or ⌘T) waiting for something to be opened in it.
/// Pinned tabs (`isPinned`) sit leftmost in their pane, keep their item and come back on relaunch.
/// A new tab whose address field is opening a link holds it in `openingURL` until the item is stored.
struct ReaderTab: Identifiable, Equatable, Sendable {
    let id = UUID()
    var itemID: Int64?
    var isNew = false
    var isPinned = false
    var openingURL: String?
    /// What the tab showed before (newest last) and, after going back, what it showed after: Back and Forward.
    var back: [ReaderTabPage] = []
    var forward: [ReaderTabPage] = []

    var page: ReaderTabPage { ReaderTabPage(itemID: itemID, isNew: isNew) }
}

/// One thing a tab showed: an item, or the New Tab page (Explore).
struct ReaderTabPage: Equatable, Sendable {
    var itemID: Int64?
    var isNew: Bool
}

/// A reader column (split view has two): its tabs and the one showing.
struct ReaderPane: Equatable, Sendable {
    var tabs: [ReaderTab] = [ReaderTab()]
    var active = 0
    var activeTab: ReaderTab { tabs[active] }
    /// Pinned tabs come first, so this is also the index of the first unpinned one.
    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Removes a tab and moves `active` in the same step: the tab after it takes its place, or the one
    /// before if it was last, and a tab before the active one shifts it down. `AppModel.panes` observes
    /// every write, so a pane must never be written with `active` past its tabs (change a copy, then
    /// assign it once).
    mutating func removeTab(at index: Int) {
        tabs.remove(at: index)
        if index < active || active >= tabs.count { active = max(active - 1, 0) }
    }
}

/// A reader tab being dragged: where it was picked up, so the other pane (or the right half of a
/// lone pane) can take it.
struct ReaderTabDrag: Equatable, Sendable {
    let pane: Int
    let tabID: UUID
    /// What the drag carries, so a drop of anything else (text from another app) is ignored.
    var payload: String { "openfeed-tab:\(tabID.uuidString)" }
}

/// What a digest covers: a view (All, Saved, ...), a folder or a source (Copy Last 24 Hours / 7 Days).
enum DigestScope: Equatable, Sendable {
    case view(FeedView)
    case folder(Folder)
    case source(Source)

    /// Names the scope in the digest heading.
    var title: String {
        switch self {
        case .view(let v): v.title
        case .folder(let f): f.title
        case .source(let s): s.title
        }
    }
}

/// The small confirmation at the bottom of the window after Copy as Markdown (`CopyToastView`).
struct CopyToast: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case working, done, failed }
    let id = UUID()
    var kind: Kind
    var message: String
    /// Second line, e.g. "No transcript, so this has the show notes."
    var note: String?
}

/// A source or folder to mute or unmute, from a toast's Undo or the muted list's banner.
enum MuteTarget: Equatable, Sendable {
    case source(Int64)
    case folder(Int64)
}

/// The confirmation at the bottom of the window after muting or unmuting, with Undo (`MuteToastOverlay`).
struct MuteToast: Equatable, Identifiable, Sendable {
    let id = UUID()
    var message: String
    var target: MuteTarget
    /// What Undo sets it back to.
    var undoTo: Bool
}

/// What the banner over a muted source's or folder's list says (`MutedListBanner`).
struct MutedListNote: Equatable, Sendable {
    var text: String
    var actionTitle: String?
    var unmute: MuteTarget?
}

/// One add from the Add sources sheet.
enum SourceAddState: Equatable {
    case adding
    case added
    case failed(String)
}

/// App state and actions shared by every view. Port of the state in src/components/openfeed-app.tsx,
/// src/hooks/use-data.ts, use-search.ts and use-settings.ts. Everything is local (AppDatabase).
///
/// Navigation mirrors the web URL state: one of view / source / folder, an optional search query,
/// and an optional selected item. Changing view/source/folder clears the item and the search.
///
/// Desktop reading: one reader pane, or two side by side (split view), each with its own tabs. The
/// list, j/k and the item shortcuts act on the focused pane's active tab (`selectedItem`).
@MainActor
@Observable
final class AppModel {
    let services: OpenDispatchServices
    /// Read state and History.
    let history: HistoryStore
    /// Explore: the last search and its results, shared by the New Tab pages and the iPhone's Explore page.
    let explore: ExploreStore
    /// Topics (followed keyword searches) and their unread counts.
    let topicStore: TopicStore
    /// The sites signed in to in the app (X, Reddit), for Explore's posts and the reader's replies.
    let accounts: WebAccountStore
    /// The app icon chosen in Settings → Appearance.
    let appIcon = AppIconStore()
    @ObservationIgnored private var transcripts: [Int64: Transcript] = [:]
    var database: AppDatabase { services.database }

    // MARK: Navigation (read-only outside; use navigate(...))

    private(set) var selectedView: FeedView = .all
    private(set) var selectedSourceID: Int64?
    private(set) var selectedFolderID: Int64?
    /// The opened item: the focused pane's active tab. nil = nothing opened (see `selectedItem` for
    /// the default-selection rule).
    var selectedItemID: Int64? { panes[focusedPane].activeTab.itemID }
    /// Tablet/desktop: with nothing opened, show the first item (the web app's md+ behavior). Set by RootView.
    var prefersDefaultSelection = false
    /// The Highlights view (sidebar, the iPhone drawer) is showing instead of an item list: the articles
    /// that have highlights, which HighlightStore lists. Any other navigation turns it off.
    private(set) var showsHighlights = false
    /// The History view (sidebar, the iPhone drawer) is showing instead of an item list: what was opened,
    /// newest first, which HistoryStore lists. Any other navigation turns it off.
    private(set) var showsHistory = false
    /// The iPhone's Explore page (drawer row) is showing instead of an item list. Any other navigation
    /// turns it off. (On the Mac and iPad Explore is the New Tab page, which is not a navigation state.)
    private(set) var showsExplore = false
    /// Which kind of item a topic's list shows (the chips under its header). Back to All whenever the list
    /// moves to something else.
    private(set) var topicFilter: TopicContentFilter = .all
    /// Bumped when Explore is picked on the iPhone, so its page puts the cursor in the search field.
    private(set) var exploreFocusRequests = 0
    /// Hide Read Items: items read before this moment are left out of the list. Moved on when the list is
    /// navigated or refreshed, so what you read while a list shows stays until then.
    private var hideReadCutoff = Date()

    // MARK: Search (use-search.ts): the draft follows typing; it is committed after 250 ms.

    /// Bound to the search field.
    var searchDraft = "" {
        didSet { scheduleSearchCommit() }
    }
    /// Committed query used for the list.
    private(set) var searchQuery = ""
    var isSearchOpen = false

    // MARK: Sidebar source filter (⌘K)

    /// Text in the sidebar's source filter; matching sources replace the tree while it is non-blank.
    var sourceFilter = ""
    var isSourceFilterOpen = false
    /// Bumped by ⌘K so the field takes focus even when it is already open.
    private(set) var sourceFilterFocusRequests = 0
    /// Bumped by ⌘L so the New Tab page's address field takes focus.
    private(set) var addressFocusRequests = 0
    /// The sidebar's collapsed-by-default "Hidden" group is open. Session only.
    var isHiddenGroupExpanded = false
    /// The sidebar's collapsed-by-default "More" row, which holds the hidden views, is open. Session only.
    var isMoreViewsExpanded = false

    // MARK: Layout state

    /// Desktop sidebar hidden (⌘\). Persisted.
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }
    /// Full-screen reader (⇧⌘F): hides sidebar and list while an item is open. Session only.
    var focusMode = false
    /// Reader panes: one, or two in split view, each with its own tabs. Session only.
    private(set) var panes: [ReaderPane] = [ReaderPane()] {
        didSet {
            recordTabHistory(from: oldValue)
            recordShownItems()
        }
    }
    /// Set while Back or Forward moves a tab, so the move isn't recorded as a new page.
    @ObservationIgnored private var movingInHistory = false
    /// The pane the list, j/k and the item shortcuts act on.
    private(set) var focusedPane = 0
    /// The left pane's share of the reader's width in split view.
    var splitFraction: CGFloat = 0.5
    /// The tab being dragged, from drag start until it drops or the pointer moves on (SwiftUI has no
    /// drag-ended callback). The reader shows its drop targets only meanwhile.
    var tabDrag: ReaderTabDrag?
    /// Collapsed sidebar folders: folder id as a string, or "unfiled". Persisted.
    var collapsedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedFolders), forKey: Keys.collapsedFolders) }
    }
    /// Sidebar views moved into "More" (Hide from Sidebar), by `SidebarViewItem.id`. Persisted per device.
    var hiddenSidebarViews: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenSidebarViews), forKey: Keys.hiddenSidebarViews) }
    }

    // MARK: Presentation flags (sheets / dialogs)

    var isAddSourcePresented = false
    /// The Topic sheet (New Topic…, Edit Topic…); nil when closed.
    var topicEditor: TopicEditorRequest?
    /// URL to prefill in the Add source sheet (deep link `opendispatch://add?url=…`); the sheet clears it.
    var pendingAddSourceURL: String?
    /// Folder the Add source sheet puts what it adds into (the drawer's "Add Source to <Folder>…"); the
    /// sheet takes it when it opens. nil adds to No Folder.
    var pendingAddSourceFolderID: Int64?
    /// Adds started from the Add sources sheet, by the URL added (a feed or a site).
    private(set) var sourceAdds: [String: SourceAddState] = [:]
    /// The folder each add in `sourceAdds` goes into, when one was picked.
    private var sourceAddFolders: [String: Int64] = [:]
    /// The source each add in `sourceAdds` made or found, once it has.
    private var sourceAddIDs: [String: Int64] = [:]
    var isShortcutsPresented = false
    /// Settings: the sheet on iOS/iPad, the in-window overlay on macOS. `settingsTab` picks the pane.
    var isSettingsPresented = false
    var settingsTab: SettingsTab = .sources

    // MARK: Data

    /// The list as shown: `loadedItems` without the articles from paywalled sites when the list hides them (`hidesPaywalled`).
    private(set) var items: [FeedItem] = []
    /// How many of the loaded items the list leaves out for their paywall, for the list's footer.
    private(set) var hiddenPaywalledCount = 0
    private(set) var nextCursor: ItemCursor?
    /// Rows the last reload of the same list added (a refresh), for the list's new-items pill. Empty after a load
    /// of another list, or the first load of one.
    private(set) var arrivedItemIDs: Set<Int64> = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// Set when the list failed to load ("Could not load items. Retry").
    private(set) var loadError: String?
    private(set) var sources: [Source] = []
    private(set) var folders: [Folder] = []
    private(set) var counts: ItemCounts = .empty
    private(set) var lastRefreshAt: Date?
    private(set) var isRefreshing = false
    private(set) var lastRefreshResult: RefreshResult?
    private(set) var integrations = IntegrationsState()
    /// Bumped per item by Reload Article; the reader showing that item re-extracts when it changes.
    private(set) var articleReloads: [Int64: Int] = [:]
    /// The Copy as Markdown confirmation while it shows; nil otherwise.
    private(set) var copyToast: CopyToast?
    private(set) var muteToast: MuteToast?

    /// Reader settings, theme, playback. Persisted on change, and mirrored into the database for iCloud sync.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            ThemeRuntime.shared.apply(settings)
            if !applyingSyncedSettings { mirrorSettingsForSync() }
            if settings.hideReadItems != oldValue.hideReadItems {
                hideReadCutoff = Date()
                Task { await loadItems(reset: true) }
            }
            if settings.paywallTreatment != oldValue.paywallTreatment { PaywallTreatment.current = settings.paywallTreatment }
            if settings.paywallTreatment != oldValue.paywallTreatment || settings.paywalls != oldValue.paywalls { applyPaywallFilter() }
            if settings.feedOrder != oldValue.feedOrder { Task { await loadItems(reset: true) } }
        }
    }

    // MARK: iCloud sync

    /// iCloud sync on this device (Settings → Data). Persisted; on by default.
    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            UserDefaults.standard.set(syncEnabled, forKey: Keys.syncEnabled)
            // Chained, so quick off/on flips reach CloudSync in order.
            let previous = syncToggle, on = syncEnabled, sync = sync!
            syncToggle = Task {
                await previous?.value
                await sync.setEnabled(on)
            }
        }
    }
    private(set) var syncStatus: CloudSyncStatus = .off

    // MARK: Private

    @ObservationIgnored private var loadGeneration = 0
    /// Every item the query returned so far, paywalled ones included; `items` is this as the list shows it.
    @ObservationIgnored private var loadedItems: [FeedItem] = []
    /// Show on the list's footer: the hidden paywalled items are shown until you go to another list.
    @ObservationIgnored private var showsPaywalled = false
    /// Items whose article was read for the paywall book this launch, so each counts once.
    @ObservationIgnored private var learnedPaywalls: Set<Int64> = []
    /// The query `nextCursor` belongs to; paging a different query from it would append wrong rows.
    @ObservationIgnored private var cursorQuery: ItemQuery?
    /// Every item open in a tab, so a tab keeps its item when the list moves on (another feed, a
    /// search, a deep link to an item outside the page). Pruned to the open tabs.
    private var openItems: [Int64: FeedItem] = [:]
    /// The sidebar's state before split view folded it away; restored when the split closes.
    @ObservationIgnored private var sidebarCollapsedBeforeSplit: Bool?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The copy in flight and the timer that clears its toast; a newer copy replaces both.
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    @ObservationIgnored private var muteToastTimer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var applyingSyncedSettings = false
    @ObservationIgnored private var syncToggle: Task<Void, Never>?
    /// Created in init; its events come back to `handleSync(_:)` on the main actor.
    @ObservationIgnored private var sync: CloudSync!
    /// Reads ahead of the open article (ArticlePrefetcher.swift).
    @ObservationIgnored private var prefetcher: ArticlePrefetcher!
    /// The way j/k last moved through the list (1 down, -1 up); reading ahead follows it.
    @ObservationIgnored private var readingStep = 1
    /// Items shown in a pane's active tab when the panes last changed, so only newly shown ones are recorded.
    @ObservationIgnored private var shownItemIDs: Set<Int64> = []
    /// The item last opened by the user (a click, j/k, a link): only it autoplays (Autoplay on select). An
    /// item the reader shows as the list's first, such as a new video arriving at the top, waits for play.
    private(set) var autoplayItemID: Int64?

    /// UserDefaults keys keep the app's original name so existing settings carry over.
    private enum Keys {
        static let sidebarCollapsed = "openfeed.sidebar-collapsed"
        static let collapsedFolders = "openfeed.sidebar.collapsed"
        static let hiddenSidebarViews = "openfeed.sidebar.hidden-views"
        static let syncEnabled = "openfeed.icloud-sync"
        static let pinnedTabs = "openfeed.pinned-tabs"
    }

    init(services: OpenDispatchServices) {
        self.services = services
        history = HistoryStore(database: services.database)
        accounts = WebAccountStore()
        explore = ExploreStore(services: services, accounts: accounts)
        topicStore = TopicStore(database: services.database)
        let defaults = UserDefaults.standard
        sidebarCollapsed = defaults.bool(forKey: Keys.sidebarCollapsed)
        collapsedFolders = Set(defaults.stringArray(forKey: Keys.collapsedFolders) ?? [])
        hiddenSidebarViews = Set(defaults.stringArray(forKey: Keys.hiddenSidebarViews) ?? [])
        let loaded = AppSettings.load()
        settings = loaded
        PaywallTreatment.current = loaded.paywallTreatment
        ThemeRuntime.shared.apply(loaded)
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? true
        sync = CloudSync(database: services.database) { [weak self] event in
            await self?.handleSync(event)
        }
        prefetcher = ArticlePrefetcher(services: services)
        prefetcher.onFetched = { [weak self] id, result in self?.didFetchContent(id, result) }
        accounts.onSitesChange = { [weak self] in self?.applyPaywallFilter() }
    }

    /// Opens the on-disk database; falls back to an in-memory one if that fails (the app still runs).
    static func live() -> AppModel {
        let db: AppDatabase
        do {
            db = try AppDatabase.openDefault()
        } catch {
            // Last resort so the UI can show something; data will not persist this session.
            db = try! AppDatabase.inMemory()
        }
        return AppModel(services: .live(database: db))
    }

    /// In-memory, seeded model for SwiftUI previews.
    static func preview() -> AppModel {
        // In-memory database creation only fails on programmer error.
        let db = try! AppDatabase.inMemory(seed: true)
        return AppModel(services: .live(database: db))
    }

    // MARK: Lifecycle

    /// First load: sources, items, stats, integrations, then a non-forced refresh. Safe to call repeatedly.
    func start() async {
        guard !started else { return }
        started = true
        appIcon.showInDock()
        // Read first and alongside the rest: a restored X post waits on it for its replies.
        let signIns = Task { await accounts.refresh() }
        // Topics stored by an older build, or before their rules last changed, match today's rules before anything lists them.
        _ = try? await database.tidyTopics()
        await loadSources()
        await loadItems(reset: true)
        await restorePinnedTabs()
        await loadStats()
        await loadIntegrations()
        await signIns.value
        // A search made before then skipped X.
        if accounts.isSignedIn(.x), explore.posts[.x]?.value == nil, explore.posts[.x]?.isLoading != true { explore.retryPosts(.x) }
        // Not awaited: the first fetch from iCloud must not hold up the first refresh.
        Task { await startSync() }
        await refresh(force: false)
        await prefetcher.queueSaved()
    }

    // MARK: Derived

    /// The ItemQuery for the current navigation and search.
    var currentQuery: ItemQuery {
        ItemQuery(view: selectedView, sourceId: selectedSourceID, folderId: selectedFolderID, search: searchQuery,
                  hideReadBefore: hidesReadItems ? hideReadCutoff : nil,
                  topicFilter: isTopicSelected ? topicFilter : .all, order: listOrder)
    }

    /// Feed order applies to All, its type views and topics; a source, folder, Saved and a search stay newest first.
    var listOrder: FeedOrder {
        (isInSourceFeed && !isTopicSelected) || selectedView == .saved || !searchQuery.isEmpty ? .latest : settings.feedOrder
    }

    /// Hide Read Items applies here: it's on, and the list isn't Saved (kept on purpose) or a search.
    var hidesReadItems: Bool {
        settings.hideReadItems && !(selectedView == .saved && !isInSourceFeed) && searchQuery.isEmpty
    }

    /// The selected source: a subscription, or a topic (which `sources` leaves out).
    var activeSource: Source? { selectedSourceID.flatMap { id in sources.first { $0.id == id } ?? topicStore.topic(id: id) } }
    /// The topics, in sidebar order.
    var topics: [Source] { topicStore.topics }
    /// The list is a topic's.
    var isTopicSelected: Bool { selectedSourceID.map { topicStore.ids.contains($0) } ?? false }
    var activeTopic: Source? { selectedSourceID.flatMap { topicStore.topic(id: $0) } }
    var activeFolder: Folder? { selectedFolderID.flatMap { id in folders.first { $0.id == id } } }
    /// A source or folder feed (not one of the views).
    var isInSourceFeed: Bool { selectedSourceID != nil || selectedFolderID != nil }

    /// Header title: source title, folder title, or the view name.
    var listTitle: String {
        showsHighlights ? "Highlights" : showsHistory ? "History" : showsExplore ? "Explore" : activeSource?.title ?? activeFolder?.title ?? selectedView.title
    }

    /// The list's title with a topic's active filter after it ("Firefox · Videos"): what the title menu's button reads.
    var listHeading: String {
        isTopicSelected && topicFilter != .all ? "\(listTitle) \u{00B7} \(topicFilter.title)" : listTitle
    }

    /// Search field placeholder: "Search" in All, else "Search <title>".
    var searchPlaceholder: String { listTitle == "All" ? "Search" : "Search \(listTitle)" }

    /// The item the reader shows: the opened one, else (tablet/desktop) the first in the list.
    var selectedItem: FeedItem? { activeItem(inPane: focusedPane) }

    /// Id the list highlights (the opened item or the default first one). A story's other outlets, its Hacker News thread and
    /// its posts are not rows of their own, so opening one highlights the story's row (its lead), and j/k move on from there.
    var highlightedItemID: Int64? {
        guard let id = selectedItem?.id, !items.contains(where: { $0.id == id }) else { return selectedItem?.id }
        let lead = items.first { row in
            guard let story = row.story else { return false }
            return story.discussion?.id == id || story.outlets.contains { $0.id == id } || story.posts.contains { $0.id == id }
        }
        return lead?.id ?? id
    }

    /// The other pane's item in split view, which the list marks more lightly.
    var secondaryHighlightedItemID: Int64? { isSplit ? activeItem(inPane: 1 - focusedPane)?.id : nil }

    /// Items open in some tab, shown or not (the list marks the ones in background tabs).
    /// The items the tabs show, or show again on Back or Forward.
    var openItemIDs: Set<Int64> {
        Set(panes.flatMap { $0.tabs.flatMap { [$0.itemID] + ($0.back + $0.forward).map(\.itemID) }.compactMap { $0 } })
    }

    var isSplit: Bool { panes.count > 1 }

    /// ⌘W closes a tab instead of the window: there's a split, more than one tab, or the one tab
    /// isn't already a new tab.
    var hasReaderTabs: Bool { isSplit || panes[0].tabs.count > 1 || !panes[0].activeTab.isNew }

    /// Items from closed tabs, most recent first (⇧⌘T). Session only.
    private(set) var closedItems: [FeedItem] = []

    /// What a tab shows: its item, or with none opened (tablet/desktop) the first in the list that
    /// isn't pinned, so the default tab never repeats a pin (the newest item pinned last launch).
    func item(for tab: ReaderTab) -> FeedItem? {
        if tab.isNew { return nil }
        if let id = tab.itemID { return items.first { $0.id == id } ?? openItems[id] }
        guard prefersDefaultSelection, !showsHighlights, !showsHistory else { return nil }
        let pinned = Set(panes.flatMap { $0.tabs.filter(\.isPinned).compactMap(\.itemID) })
        return items.first { !pinned.contains($0.id) }
    }

    /// What a pane shows: its active tab's item.
    func activeItem(inPane pane: Int) -> FeedItem? {
        panes.indices.contains(pane) ? item(for: panes[pane].activeTab) : nil
    }

    /// Folders in sidebar order (position, id).
    var orderedFolders: [Folder] {
        folders.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    /// Sources shown in a folder (nil = No Folder) in sidebar order: position, then title. Pinned and hidden
    /// sources are listed in their own groups instead.
    func sources(inFolder folderId: Int64?) -> [Source] {
        SourceList.inFolder(sources, folderId)
    }

    /// Every source of a folder, pinned and hidden included (iPhone Sources screen, which has no such groups).
    func allSources(inFolder folderId: Int64?) -> [Source] {
        SourceList.allInFolder(sources, folderId)
    }

    /// Sidebar "Pinned" group, in pin order.
    var pinnedSources: [Source] { SourceList.pinned(sources) }

    /// Sidebar "Hidden" group, by title.
    var hiddenSources: [Source] { SourceList.hidden(sources) }

    /// Sources matching the sidebar filter field, flat and by title; empty while the field is blank.
    var filteredSources: [Source] { SourceList.matching(sources, query: sourceFilter) }

    /// True while the sidebar shows filter matches instead of the tree.
    var isFilteringSources: Bool { !sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var isPinnedGroupCollapsed: Bool { collapsedFolders.contains(Self.pinnedKey) }

    func togglePinnedGroupCollapsed() {
        if collapsedFolders.contains(Self.pinnedKey) { collapsedFolders.remove(Self.pinnedKey) } else { collapsedFolders.insert(Self.pinnedKey) }
    }

    private static let pinnedKey = "pinned"

    func isFolderCollapsed(_ folderId: Int64?) -> Bool { collapsedFolders.contains(Self.folderKey(folderId)) }

    func toggleFolderCollapsed(_ folderId: Int64?) {
        let key = Self.folderKey(folderId)
        if collapsedFolders.contains(key) { collapsedFolders.remove(key) } else { collapsedFolders.insert(key) }
    }

    static func folderKey(_ folderId: Int64?) -> String { folderId.map(String.init) ?? "unfiled" }

    func isSidebarViewHidden(_ item: SidebarViewItem) -> Bool { hiddenSidebarViews.contains(item.id) }

    /// Moves a view into the sidebar's "More" row, or back out. All can't be hidden.
    func setSidebarView(_ item: SidebarViewItem, hidden: Bool) {
        guard item.isHideable else { return }
        if hidden { hiddenSidebarViews.insert(item.id) } else { hiddenSidebarViews.remove(item.id) }
    }

    // MARK: Navigation

    /// Show a view (All, Saved, Articles, ...). Clears source/folder, item and search.
    func navigate(view: FeedView) {
        setNav(view: view, source: nil, folder: nil)
    }

    /// Show a view, with `rows` (its first rows, already loaded) in the list until its first page loads.
    func navigate(view: FeedView, startingWith rows: [FeedItem]) {
        setNav(view: view, source: nil, folder: nil, startingWith: rows)
    }

    /// Show one source's feed.
    func navigate(sourceID: Int64) {
        setNav(view: .all, source: sourceID, folder: nil)
    }

    /// Show one folder's feed.
    func navigate(folderID: Int64) {
        setNav(view: .all, source: nil, folder: folderID)
    }

    /// All, no source/folder (HOME).
    func goHome() { navigate(view: .all) }

    /// Show the Highlights view: the articles with highlights, under Saved.
    func showHighlights() {
        setNav(view: .saved, source: nil, folder: nil)
        showsHighlights = true
    }

    /// Show the History view: what was opened, newest first.
    func showHistory() {
        setNav(view: .all, source: nil, folder: nil)
        showsHistory = true
    }

    /// Show the iPhone's Explore page (the drawer's first row). The Mac and iPad open the New Tab page instead.
    func showExplore(focusingSearch: Bool = true) {
        setNav(view: .all, source: nil, folder: nil)
        showsExplore = true
        if focusingSearch { exploreFocusRequests += 1 }
    }

    private func setNav(view: FeedView, source: Int64?, folder: Int64?, startingWith rows: [FeedItem] = []) {
        let changed = view != selectedView || source != selectedSourceID || folder != selectedFolderID || !searchQuery.isEmpty
        showsHighlights = false
        showsHistory = false
        showsExplore = false
        if changed {
            hideReadCutoff = Date()
            showsPaywalled = false
        }
        selectedView = view
        if source != selectedSourceID { topicFilter = .all }
        selectedSourceID = source
        topicStore.watchFilterCounts(of: source.flatMap { topicStore.ids.contains($0) ? $0 : nil })
        selectedFolderID = folder
        setActiveItem(nil)
        resetSearchState()
        guard changed else { return }
        if !rows.isEmpty {
            loadedItems = rows
            nextCursor = nil
            applyPaywallFilter()
        }
        Task { await loadItems(reset: true) }
    }

    // MARK: Items

    /// Reload the first page for the current query (reset) or load the next page. `keepingDepth` (a refresh) reloads
    /// as many rows as were paged in, up to 200, so the list doesn't shrink under someone reading further down.
    /// `countsNewRows` is false when rows join the list without being new (muting moves older ones up), so the pill stays away.
    func loadItems(reset: Bool = true, keepingDepth: Bool = false, countsNewRows: Bool = true) async {
        guard reset else { return await loadMore() }
        loadGeneration += 1
        let gen = loadGeneration
        let query = currentQuery
        var request = query
        if keepingDepth { request.limit = min(max(ItemQuery.defaultLimit, loadedItems.count + ItemQuery.defaultLimit), 200) }
        isLoading = true
        do {
            let page = try await database.items(request)
            guard gen == loadGeneration else { return }
            let before = Set(loadedItems.map(\.id))
            let arrived = countsNewRows && cursorQuery?.listIdentity == query.listIdentity && !before.isEmpty
                ? Set(page.items.map(\.id)).subtracting(before) : []
            if arrived != arrivedItemIDs { arrivedItemIDs = arrived }
            loadedItems = page.items
            applyPaywallFilter()
            nextCursor = page.nextCursor
            cursorQuery = query
            loadError = nil
        } catch {
            if gen == loadGeneration { loadError = HTTP.message(error) }
        }
        if gen == loadGeneration { isLoading = false }
    }

    /// Next page (infinite scroll). No-op without a cursor, while loading, or when the cursor is stale.
    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, cursorQuery == currentQuery else { return }
        let gen = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await database.items(currentQuery.after(cursor))
            guard gen == loadGeneration else { return }
            let seen = Set(loadedItems.map(\.id))
            loadedItems.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            applyPaywallFilter()
            nextCursor = page.nextCursor
        } catch {
            // Keep the cursor; the sentinel retries.
        }
    }

    /// Open an item in the focused pane's active tab (nil closes the reader).
    func select(_ item: FeedItem?) {
        if let item { openItems[item.id] = item }
        setActiveItem(item?.id)
    }

    /// Open an item by id (deep link); loads it if it is not in the current page.
    func select(itemID: Int64) async {
        setActiveItem(itemID)
        if items.contains(where: { $0.id == itemID }) { return }
        if let it = try? await database.feedItem(id: itemID), selectedItemID == itemID {
            openItems[itemID] = it
            history.recordOpen(it)
        }
    }

    /// j/k: select the next (1) or previous (-1) item; prefetches the next page near the end.
    func moveSelection(by step: Int) {
        guard !items.isEmpty, !showsHighlights, !showsHistory, !showsExplore else { return }
        let from = highlightedItemID
        let i = items.firstIndex { $0.id == from } ?? -1
        let target = i < 0 ? 0 : min(max(i + step, 0), items.count - 1)
        if step > 0, nextCursor != nil, i + step >= items.count - 5 { Task { await loadMore() } }
        let next = items[target]
        if next.id == from { return }
        readingStep = step < 0 ? -1 : 1
        select(next)
    }

    /// Optimistic save/unsave; reverts if the write fails.
    func toggleSaved(_ item: FeedItem) async {
        let saved = !item.isSaved
        patchLocal(item.id) { $0.item.isSaved = saved }
        do {
            try await database.setSaved(itemId: item.id, saved: saved)
            counts = (try? await database.counts()) ?? counts
            if saved { await prefetcher.queueSaved() }
        } catch {
            patchLocal(item.id) { $0.item.isSaved = !saved }
        }
    }

    // MARK: Read state

    /// Mark as Read / Unread (row menus, `m`).
    func toggleRead(_ item: FeedItem) { history.toggleRead(item) }

    /// Keyboard `m`: the selected item.
    func toggleReadOnSelection() {
        if let it = selectedItem { history.toggleRead(it) }
    }

    /// Mark All as Read: every item of the current list, all pages. With Hide Read Items on they stay
    /// until the list is next refreshed.
    func markAllRead() {
        let query = currentQuery
        Task { try? await database.markAllRead(query) }
    }

    func toggleHideReadItems() { settings.hideReadItems.toggle() }

    /// Open a History entry; an article this device no longer has (or never had) is added back from the
    /// entry, or opens in the browser when its source isn't here.
    func open(_ entry: HistoryEntry, inNewTab: Bool = false) async {
        guard let item = try? await database.itemForHistory(entry) else {
            if let url = URL(string: entry.itemUrl) { ReaderWebSupport.openExternally(url) }
            return
        }
        if inNewTab { openInNewTab(item) } else { open(item) }
    }

    /// Records the items a pane's active tab newly shows as opened. The list's first item shown by default
    /// (no item picked) doesn't count.
    // MARK: Back and Forward

    private static let tabHistoryLimit = 50

    /// A tab that went on to show something else (an item opened in it, Explore filling it) keeps what it showed for Back,
    /// and loses what Forward had. A tab following the list's first item has nothing to go back to.
    private func recordTabHistory(from old: [ReaderPane]) {
        guard !movingInHistory else { return }
        var before: [UUID: ReaderTabPage] = [:]
        for pane in old { for tab in pane.tabs { before[tab.id] = tab.page } }
        var changed = false
        var next = panes
        for p in next.indices {
            for t in next[p].tabs.indices {
                let tab = next[p].tabs[t]
                guard let was = before[tab.id], was != tab.page, was.itemID != nil || was.isNew else { continue }
                next[p].tabs[t].back.append(was)
                if next[p].tabs[t].back.count > Self.tabHistoryLimit { next[p].tabs[t].back.removeFirst() }
                next[p].tabs[t].forward = []
                changed = true
            }
        }
        if changed {
            movingInHistory = true
            panes = next
            movingInHistory = false
        }
    }

    var canGoBack: Bool { !panes[focusedPane].activeTab.back.isEmpty }
    var canGoForward: Bool { !panes[focusedPane].activeTab.forward.isEmpty }

    /// Back (⌘[): the focused pane's active tab shows what it showed before.
    func goBack() { moveInHistory(back: true) }
    /// Forward (⌘]): undoes a Back.
    func goForward() { moveInHistory(back: false) }

    private func moveInHistory(back: Bool) {
        let p = focusedPane
        var pane = panes[p]
        var tab = pane.activeTab
        guard let target = back ? tab.back.popLast() : tab.forward.popLast() else { return }
        if back { tab.forward.append(tab.page) } else { tab.back.append(tab.page) }
        tab.itemID = target.itemID
        tab.isNew = target.isNew
        tab.openingURL = nil
        pane.tabs[pane.active] = tab
        movingInHistory = true
        panes[p] = pane
        movingInHistory = false
    }

    private func recordShownItems() {
        let shown = Set(panes.compactMap { $0.activeTab.isNew ? nil : $0.activeTab.itemID })
        let added = shown.subtracting(shownItemIDs)
        shownItemIDs = shown
        let focused = panes[focusedPane].activeTab.itemID
        if let id = focused.flatMap({ added.contains($0) ? $0 : nil }) ?? added.first { autoplayItemID = id }
        for id in added {
            if let item = openItems[id] ?? items.first(where: { $0.id == id }) { history.recordOpen(item) }
        }
    }

    /// Toggle saved on the selected item (keyboard `s`).
    func toggleSavedOnSelection() async {
        if let it = selectedItem { await toggleSaved(it) }
    }

    /// Applies `change` to the item wherever it is held. `items` and `openItems` are only written when the item
    /// actually changes: any write to `items` makes the list update every row it has.
    private func patchLocal(_ id: Int64, _ change: (inout FeedItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            var row = items[i]
            change(&row)
            if row != items[i] { items[i] = row }
        }
        if let i = loadedItems.firstIndex(where: { $0.id == id }) { change(&loadedItems[i]) }
        if let old = openItems[id] {
            var p = old
            change(&p)
            if p != old { openItems[id] = p }
        }
    }

    /// Reader content (cached or freshly extracted). Marks the row as having content. Reading ahead
    /// stops while it loads (joining its extraction if it was already fetching this item) and starts
    /// again from here once it has, when this is the focused pane's article.
    func content(for item: FeedItem, refresh: Bool = false) async throws -> ExtractResult {
        prefetcher.stop(except: item.id)
        let result: ExtractResult
        if !refresh, let ahead = prefetcher.inFlight(item.id), let done = try? await ahead.value {
            result = done
        } else {
            result = try await services.content.content(forItem: item.id, refresh: refresh)
        }
        didFetchContent(item.id, result, url: item.item.url)
        if item.id == selectedItemID, !showsHighlights, !showsHistory, !showsExplore { prefetcher.readAhead(from: item.id, in: items, step: readingStep) }
        return result
    }

    /// Having text is noted with the prefetcher, not on the row: the row doesn't show it, and every article read ahead
    /// changing `items` made the list update all its rows mid-scroll. A lead image the row lacks does change the row.
    private func didFetchContent(_ id: Int64, _ result: ExtractResult, url: String? = nil) {
        if result.contentHtml != nil {
            learnPaywall(id, url: url, result)
            prefetcher.noteContent(id)
        }
        guard let lead = result.leadImage else { return }
        patchLocal(id) { row in
            if row.item.thumbnailUrl == nil { row.item.thumbnailUrl = lead }
        }
    }

    // MARK: Paywalls

    /// Hide applies to this list: the setting is Hide, and the list isn't Saved (kept on purpose) or a search, nor revealed
    /// by the footer's Show.
    var hidesPaywalled: Bool {
        settings.paywallTreatment == .hide && !showsPaywalled && !(selectedView == .saved && !isInSourceFeed) && searchQuery.isEmpty
    }

    /// How the item's site stands for the list's mark (a lock and "Subscribers"); `.free` when the setting is Show. A topic's
    /// news item names its publisher in the author (an aggregator carries the article under its own address), and a story
    /// row stands for its lead.
    func paywallStatus(of item: FeedItem) -> PaywallStatus {
        guard settings.paywallTreatment != .show else { return .free }
        return status(url: item.item.url, publisher: item.source.isTopic ? item.item.author : nil)
    }

    /// The same mark for an Explore article, whose outlet is the publisher (an aggregator carries it under its own address).
    func paywallStatus(of article: ExploreArticle) -> PaywallStatus {
        guard settings.paywallTreatment != .show else { return .free }
        return status(url: article.url, publisher: article.outlet)
    }

    /// Explore's articles as the section shows them: with Hide, the walled sites' left out (metered ones stay, marked).
    func shownArticles(_ articles: [ExploreArticle]) -> [ExploreArticle] {
        guard settings.paywallTreatment == .hide else { return articles }
        return articles.filter { paywallStatus(of: $0) != .walled }
    }

    private func status(url: String, publisher: String?) -> PaywallStatus {
        Paywalls.status(url: url, publisher: publisher, signedIn: accounts.signedInSites, book: settings.paywalls)
    }

    /// The list leaves the item out: its site is walled, and for a story row, so is every outlet's.
    private func isHiddenForPaywall(_ item: FeedItem) -> Bool {
        guard paywallStatus(of: item) == .walled else { return false }
        return item.story?.outlets.allSatisfy { status(url: $0.url, publisher: $0.name) == .walled } ?? true
    }

    /// Rebuilds `items` from `loadedItems`, leaving out what the list hides. An item open in a tab stays, so reading it
    /// (which can teach the book its site is walled) doesn't pull it out from under the reader.
    private func applyPaywallFilter() {
        var shown = loadedItems
        if hidesPaywalled {
            let open = openItemIDs
            shown = loadedItems.filter { open.contains($0.id) || !isHiddenForPaywall($0) }
        }
        if shown != items { items = shown }
        let hidden = loadedItems.count - shown.count
        if hidden != hiddenPaywalledCount { hiddenPaywalledCount = hidden }
    }

    /// The list's footer Show: the hidden items appear until you go to another list.
    func showHiddenPaywalled() {
        showsPaywalled = true
        applyPaywallFilter()
    }

    /// Teaches the book what this article was: cut short, or read in full. Once per item per launch.
    private func learnPaywall(_ id: Int64, url: String?, _ result: ExtractResult) {
        guard learnedPaywalls.insert(id).inserted else { return }
        if let url = url ?? loadedItems.first(where: { $0.id == id })?.item.url ?? openItems[id]?.item.url {
            settings.paywalls.record(url: url, walled: result.paywalled)
        } else {
            // A saved article fetched in the background, outside the list.
            Task {
                guard let url = try? await database.feedItem(id: id)?.item.url else { return }
                settings.paywalls.record(url: url, walled: result.paywalled)
            }
        }
    }

    // MARK: Refresh

    /// Fetch feeds (forced, or when the last refresh is older than 15 min), then reload what changed.
    func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let r = try await services.refresh.refreshAll(force: force) { [weak self] event in
                Task { @MainActor in self?.handleRefreshProgress(event) }
            }
            lastRefreshResult = r
            if r.ran { await PostNotifications.deliver(database) }
            if force || r.ran {
                hideReadCutoff = Date()
                await reloadAll()
            } else {
                await loadStats()
            }
        } catch {
            await loadStats()
        }
    }

    /// Fetch one source (sidebar "Refresh Source"), then reload what changed.
    func refreshSource(id: Int64) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = try? await services.refresh.refreshSource(id: id)
        await PostNotifications.deliver(database)
        await reloadAll()
    }

    /// Re-extract an item's article in whichever reader shows it (Reload Article, ⇧⌘R).
    func reloadArticle(_ item: FeedItem) {
        articleReloads[item.id, default: 0] += 1
    }

    /// Live refresh progress: "updated just now" as soon as a refresh starts, and on a first launch
    /// (empty list) the first items appear as soon as one source has added some.
    private func handleRefreshProgress(_ event: RefreshProgress) {
        switch event {
        case .started(let at, _):
            lastRefreshAt = at
        case .sourceFinished(let result, _, _):
            if result.added > 0, items.isEmpty, !isLoading {
                Task { await self.loadItems(reset: true) }
            }
        case .finished:
            break
        }
    }

    /// Deep links: `opendispatch://add?url=<feed or site>` opens Add source prefilled with that URL;
    /// `opendispatch://settings?tab=<sources|appearance|playback|integrations|data|about>` opens Settings on that pane.
    /// The old `openfeed://` scheme is still accepted (and registered in project.yml) so existing links keep working.
    func handleOpenURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "opendispatch" || scheme == "openfeed" else { return }
        let action = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if action == "settings" {
            let tab = query?.first { $0.name == "tab" }?.value.flatMap { SettingsTab(rawValue: $0.lowercased()) }
            showSettings(tab ?? .sources)
            return
        }
        // opendispatch://explore?q=<query>: Explore (the iPhone page, the New Tab page elsewhere), searching q if given.
        if action == "explore" {
            let q = query?.first(where: { $0.name == "q" })?.value ?? ""
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { showExplore(focusingSearch: q.isEmpty) } else { openLocation() }
            #else
            openLocation()
            #endif
            if !q.isEmpty { explore.search(q) }
            return
        }
        guard action == "add" else { return }
        let target = query?.first { $0.name == "url" }?.value
        pendingAddSourceURL = target
        isAddSourcePresented = true
    }

    /// Sources, items, counts and stats.
    func reloadAll() async {
        await loadSources()
        await loadItems(reset: true, keepingDepth: true)
        await loadStats()
    }

    func loadStats() async {
        lastRefreshAt = (try? await database.lastRefreshAt()) ?? lastRefreshAt
    }

    // MARK: Copy as Markdown

    /// Puts one item's full text (a video's or podcast's transcript) on the clipboard as Markdown.
    func copyMarkdown(item: FeedItem) {
        let prompt = copyPrompt
        runCopy { [copy = services.copy] in
            let copied = try await copy.markdown(forItem: item.id, prompt: prompt)
            return (copied, "Copied as Markdown" + (copied.wordCount > 0 ? " \u{00B7} \(copied.wordCount.formatted()) words" : ""))
        }
    }

    /// Puts a video's transcript (as the reader shows it) on the clipboard as timestamped Markdown.
    func copyTranscript(_ transcript: Transcript, durationSec: Int?) {
        let text = transcript.markdown(durationSec: durationSec)
        let words = transcript.wordCount
        runCopy {
            (CopiedText(markdown: text, wordCount: words, itemCount: 1),
             "Copied transcript" + (words > 0 ? " \u{00B7} \(words.formatted()) words" : ""))
        }
    }

    // MARK: Transcripts

    /// A thread's comments for the reader (`ReaderComments`): a Reddit, X, Bluesky or Hacker News post's replies, or a
    /// YouTube video's comments. Not cached: each opening reads them fresh.
    func comments(for url: String) async throws -> DiscussionThread {
        try await services.discussions.comments(for: url)
    }

    /// What a "more replies" row of that thread stands for.
    func moreComments(_ more: DiscussionMore, in url: String) async throws -> [DiscussionEntry] {
        try await services.discussions.more(more, in: url)
    }

    /// The sign-in sheet closed: read the sign-ins again, and once signed in to X, search X's posts for Explore's query and
    /// refresh the topics that search X.
    func didCloseSignIn() async {
        let wasSignedIn = accounts.isSignedIn(.x)
        await accounts.refresh()
        if accounts.isSignedIn(.x), !wasSignedIn {
            for topic in topics where topic.topicOptions?.places.x == true {
                Task { await refreshTopic(id: topic.id) }
            }
        }
        if accounts.isSignedIn(.x), explore.posts[.x]?.value == nil, explore.posts[.x]?.isLoading != true { explore.retryPosts(.x) }
    }

    /// A video's transcript for the reader: YouTube's captions, fetched once per video while the app
    /// runs. nil when the video has none or the fetch failed (tried again next time it opens).
    func transcript(for item: FeedItem) async -> Transcript? {
        if let cached = transcripts[item.id] { return cached }
        guard let transcript = try? await services.copy.transcripts.transcript(for: item.item, source: item.source),
              !transcript.segments.isEmpty else { return nil }
        if transcripts.count >= 50 { transcripts.removeAll() }
        transcripts[item.id] = transcript
        return transcript
    }

    /// Puts a digest of the scope's last `days` days on the clipboard as Markdown.
    func copyDigest(_ scope: DigestScope, days: Int) {
        let prompt = copyPrompt
        let now = Date()
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let query: ItemQuery
        switch scope {
        case .view(let v): query = ItemQuery(view: v)
        case .folder(let f): query = ItemQuery(folderId: f.id)
        case .source(let s): query = ItemQuery(sourceId: s.id)
        }
        let title = scope.title
        runCopy { [copy = services.copy] in
            let copied = try await copy.digest(query, title: title, since: since, now: now, prompt: prompt)
            let span = days == 1 ? "the last 24 hours" : "the last \(days) days"
            if copied.itemCount == 0 {
                // Nothing to paste: leave the clipboard alone.
                return (nil, "Nothing in \(title) from \(span)")
            }
            return (copied, "Copied \(copied.itemCount.formatted()) \(copied.itemCount == 1 ? "item" : "items") as Markdown")
        }
    }

    /// What the list shows, as a digest scope: the source, the folder, else the view.
    var currentDigestScope: DigestScope {
        if let source = activeSource { return .source(source) }
        if let folder = activeFolder { return .folder(folder) }
        return .view(selectedView)
    }

    /// The prompt setting, trimmed; nil when empty.
    private var copyPrompt: String? {
        let text = settings.copyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Runs a copy: "Copying…" if it takes more than a moment (a transcript fetch), then the clipboard
    /// and a confirmation, or the reason it failed. A result of nil text only shows the message.
    private func runCopy(_ work: @escaping @Sendable () async throws -> (CopiedText?, String)) {
        copyTask?.cancel()
        toastTimer?.cancel()
        copyToast = nil
        copyTask = Task { [weak self] in
            let slow = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.showToast(CopyToast(kind: .working, message: "Copying\u{2026}"), for: nil)
            }
            defer { slow.cancel() }
            do {
                let (copied, message) = try await work()
                guard !Task.isCancelled else { return }
                slow.cancel()
                guard let copied else {
                    self?.showToast(CopyToast(kind: .done, message: message), for: .seconds(2))
                    return
                }
                guard !copied.markdown.isEmpty else {
                    self?.showToast(CopyToast(kind: .failed, message: "Couldn\u{2019}t copy: nothing to copy"), for: .seconds(3.5))
                    return
                }
                ReaderPasteboard.copy(copied.markdown)
                self?.showToast(CopyToast(kind: .done, message: message, note: copied.note), for: copied.note == nil ? .seconds(2) : .seconds(3.5))
            } catch {
                guard !Task.isCancelled else { return }
                slow.cancel()
                self?.showToast(CopyToast(kind: .failed, message: "Couldn\u{2019}t copy: \(HTTP.message(error))"), for: .seconds(3.5))
            }
        }
    }

    /// Shows the toast, announces it to VoiceOver, and clears it after `duration` (nil = until replaced).
    private func showToast(_ toast: CopyToast, for duration: Duration?) {
        toastTimer?.cancel()
        copyToast = toast
        announce([toast.message, toast.note].compactMap { $0 }.joined(separator: ". "))
        guard let duration else { return }
        let id = toast.id
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled, self?.copyToast?.id == id { self?.copyToast = nil }
        }
    }

    private func announce(_ text: String) {
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }

    // MARK: Sources & folders

    func loadSources() async {
        do {
            let (s, f) = try await database.sourcesAndFolders()
            sources = s
            folders = f
            counts = try await database.counts()
        } catch {
            // Keep what we had.
        }
    }

    /// "Add sources" search: feeds and podcasts matching a name. Throws when search is unavailable.
    func searchSources(_ query: String) async throws -> [SourceSearchResult] {
        try await services.search.search(query)
    }

    private let channelEmbedCheck: any YouTubeEmbedChecking = DefaultYouTubeEmbedCheck()
    private var channelPlays: [String: Bool] = [:]

    /// YouTube channels for a name or @handle.
    func searchChannels(_ query: String) async throws -> [SourceSearchResult] {
        try await services.explore.channels(query)
    }

    /// The X account with this handle, if there is one.
    func xProfile(handle: String) async throws -> SourceSearchResult? {
        try await services.xAccounts.profile(handle: handle)
    }

    /// X accounts matching a name; only while the app is signed in to X.
    func searchXAccounts(_ name: String) async throws -> [SourceSearchResult] {
        try await services.xAccounts.search(name)
    }

    func searchBluesky(_ query: String) async throws -> [SourceSearchResult] {
        try await services.socialAccounts.bluesky(query)
    }

    func searchMastodon(_ query: String) async throws -> [SourceSearchResult] {
        try await services.socialAccounts.mastodon(query)
    }

    func searchReddit(_ query: String) async throws -> [SourceSearchResult] {
        try await services.socialAccounts.reddit(query)
    }

    /// Whether a channel's videos play in this app, by its newest; nil when it can't be told. Remembered while the app runs.
    func channelPlaysHere(feedUrl: String) async -> Bool? {
        if let known = channelPlays[feedUrl] { return known }
        guard let id = URLComponents(string: feedUrl)?.queryItems?.first(where: { $0.name == "channel_id" })?.value else { return nil }
        let answer = await channelEmbedCheck.isPlayable(channelID: id)
        channelPlays[feedUrl] = answer
        return answer
    }

    /// The account a pasted link is the page of, by name; nil when it can't be told, and the link is added as it is.
    func account(for link: SourceAccountLink) async -> SourceSearchResult? {
        switch link {
        case .x(let handle):
            return (try? await xProfile(handle: handle)) ?? nil
        case .youtubeHandle(let handle):
            let found = (try? await searchChannels("@" + handle)) ?? []
            return found.first { $0.handle?.lowercased() == handle.lowercased() }
        case .youtubeChannel(let id):
            // YouTube's search doesn't know channel ids, so its name comes from its feed, without an avatar.
            guard let feed = try? await services.detector.detect(FeedDetection.youtubeFeedURL(channelID: id)) else { return nil }
            return SourceSearchResult(title: feed.title, subtitle: "YouTube", feedUrl: feed.feedUrl, siteUrl: feed.url, kind: .youtube)
        case .bluesky(let handle):
            return (try? await services.socialAccounts.blueskyProfile(handle: handle)) ?? nil
        case .reddit(let community):
            return DefaultSocialAccounts.community(community)
        case .instagram(let handle):
            return (try? await services.socialAccounts.instagramProfile(handle: handle)) ?? nil
        case .noFeed:
            return nil
        }
    }

    /// Whether a feed (a search result's feed URL) is already in the library.
    func hasSource(feedUrl: String) -> Bool {
        let key = SourceSearch.feedKey(feedUrl)
        return sources.contains { SourceSearch.feedKey($0.feedUrl) == key }
    }

    /// "Add sources": start adding without waiting. Detect the feed and store it (it shows in the sidebar),
    /// then fetch it in the background. Progress and errors land in `sourceAdds[url]`, so the sheet can
    /// stay open for more and closing it doesn't stop an add. The source goes into `folderID` when given, even
    /// if it was already in the library.
    func beginAddSource(url: String, folderID: Int64? = nil) {
        switch sourceAdds[url] {
        case .adding, .added: return
        case .failed, nil: break
        }
        sourceAdds[url] = .adding
        sourceAddFolders[url] = folderID
        Task {
            do {
                let (source, existed) = try await services.addSource(url: url, fetch: false)
                sourceAddIDs[url] = source.id
                if let folder = sourceAddFolders[url] {
                    try await moveSource(id: source.id, toFolder: folder)
                } else {
                    await loadSources()
                }
                sourceAdds[url] = .added
                guard !existed else { return }
                _ = try? await services.refresh.refreshSource(id: source.id)
                await reloadAll()
            } catch {
                sourceAdds[url] = .failed(HTTP.message(error))
                await loadSources()
            }
        }
    }

    /// Change where an add from the sheet goes, whether it is still running or done.
    func moveSourceAdd(url: String, toFolder folderID: Int64) async {
        sourceAddFolders[url] = folderID
        if let id = sourceAddIDs[url] { try? await moveSource(id: id, toFolder: folderID) }
    }

    /// Forget finished adds when the sheet closes; ones still running keep their entry.
    func clearFinishedSourceAdds() {
        sourceAdds = sourceAdds.filter { $0.value == .adding }
        sourceAddFolders = sourceAddFolders.filter { sourceAdds[$0.key] != nil }
        sourceAddIDs = sourceAddIDs.filter { sourceAdds[$0.key] != nil }
    }

    func deleteSource(id: Int64) async throws {
        try await database.deleteSource(id: id)
        closeTabs { $0.source.id == id }
        if selectedSourceID == id { goHome() }
        await loadSources()
        await loadItems(reset: true)
    }

    func renameSource(id: Int64, title: String) async throws {
        try await database.renameSource(id: id, title: title)
        await loadSources()
    }

    /// Pin to (or unpin from) the sidebar's Pinned group. The source keeps its folder.
    func setSourcePinned(id: Int64, pinned: Bool) async throws {
        try await database.setSourcePinned(id: id, pinned: pinned)
        await loadSources()
    }

    /// Notify on new posts from this source (on this device). Turning it on asks for permission first.
    func setSourceNotify(id: Int64, on: Bool) async throws {
        if on { try await requireNotificationAccess() }
        try await database.setSourceNotify(id: id, on: on)
        await loadSources()
        await topicStore.reload()
    }

    /// Asks for permission the first time; throws the message to show when notifications are off for the app.
    private func requireNotificationAccess() async throws {
        guard await PostNotifications.requestAuthorization() else {
            #if os(macOS)
            throw QueryError.invalid("Notifications are off for OpenDispatch. Turn them on in System Settings › Notifications.")
            #else
            throw QueryError.invalid("Notifications are off for OpenDispatch. Turn them on in Settings › Notifications.")
            #endif
        }
    }

    /// Hide from (or show again in) the sidebar tree. Items still appear in the views.
    func setSourceHidden(id: Int64, hidden: Bool) async throws {
        try await database.setSourceHidden(id: id, hidden: hidden)
        await loadSources()
    }

    /// The muted folder a source is filed in, if it is: muted with the folder, whatever its own setting says.
    func mutingFolder(of source: Source) -> Folder? {
        source.folderId.flatMap { id in folders.first { $0.id == id && $0.isMuted } }
    }

    /// Out of the feeds, by its own setting or its folder's.
    func isMuted(_ source: Source) -> Bool { source.isMuted || mutingFolder(of: source) != nil }

    /// The banner over the current list when it is a muted source or a folder with muted sources in it.
    var mutedListNote: MutedListNote? {
        guard !showsHighlights, !showsHistory else { return nil }
        if let id = selectedSourceID, let source = sources.first(where: { $0.id == id }), !source.isTopic {
            if let folder = mutingFolder(of: source) {
                return MutedListNote(text: "Muted with \(folder.title). Not in your feeds.", actionTitle: "Unmute Folder", unmute: .folder(folder.id))
            }
            return source.isMuted ? MutedListNote(text: "Muted. Not in your feeds.", actionTitle: "Unmute", unmute: .source(id)) : nil
        }
        guard let id = selectedFolderID, let folder = folders.first(where: { $0.id == id }) else { return nil }
        if folder.isMuted { return MutedListNote(text: "Muted. Not in your feeds.", actionTitle: "Unmute Folder", unmute: .folder(id)) }
        let list = allSources(inFolder: id)
        let muted = list.filter(\.isMuted).count
        return muted > 0 ? MutedListNote(text: "\(muted) of \(list.count) sources muted. All show here.") : nil
    }

    /// Mute in Feeds: the source's items leave All, Articles, Posts, Video and Podcasts and it stays in the sidebar.
    func setSourceMuted(id: Int64, muted: Bool, showsToast: Bool = true) async {
        do {
            let source = try await database.setSourceMuted(id: id, muted: muted)
            await reloadAfterMute()
            guard showsToast else { return }
            let place = source.isHidden ? "under Hidden" : source.folderId.flatMap { f in folders.first { $0.id == f }?.title }.map { "in \($0)" } ?? "in the sidebar"
            showMuteToast(MuteToast(
                message: muted ? "Muted \(source.shortTitle). Still \(place)." : "Unmuted \(source.shortTitle). Back in your feeds.",
                target: .source(id), undoTo: !muted))
        } catch {
            showMuteFailure(error)
        }
    }

    /// Mute Folder in Feeds: the same for every source filed in it, including ones added later.
    func setFolderMuted(id: Int64, muted: Bool, showsToast: Bool = true) async {
        do {
            let folder = try await database.setFolderMuted(id: id, muted: muted)
            await reloadAfterMute()
            guard showsToast else { return }
            let count = allSources(inFolder: id).count
            showMuteToast(MuteToast(
                message: muted
                    ? "Muted \(folder.title). \(count == 1 ? "Its source stays" : "Its \(count) sources stay") in the sidebar."
                    : "Unmuted \(folder.title). Back in your feeds.",
                target: .folder(id), undoTo: !muted))
        } catch {
            showMuteFailure(error)
        }
    }

    /// The banner's Unmute.
    func unmute(_ target: MuteTarget) async {
        switch target {
        case .source(let id): await setSourceMuted(id: id, muted: false)
        case .folder(let id): await setFolderMuted(id: id, muted: false)
        }
    }

    /// The toast's Undo.
    func undoMute() async {
        guard let toast = muteToast else { return }
        muteToastTimer?.cancel()
        muteToast = nil
        switch toast.target {
        case .source(let id): await setSourceMuted(id: id, muted: toast.undoTo, showsToast: false)
        case .folder(let id): await setFolderMuted(id: id, muted: toast.undoTo, showsToast: false)
        }
    }

    private func reloadAfterMute() async {
        await loadSources()
        await loadItems(reset: true, keepingDepth: true, countsNewRows: false)
    }

    private func showMuteToast(_ toast: MuteToast) {
        muteToastTimer?.cancel()
        muteToast = toast
        announce(toast.message)
        let id = toast.id
        muteToastTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, self?.muteToast?.id == id { self?.muteToast = nil }
        }
    }

    private func showMuteFailure(_ error: Error) {
        showToast(CopyToast(kind: .failed, message: "Couldn\u{2019}t change mute: \(HTTP.message(error))"), for: .seconds(3.5))
    }

    /// Move a source to a folder (nil = No Folder), at the end of it.
    func moveSource(id: Int64, toFolder folderId: Int64?) async throws {
        try await database.moveSource(id: id, toFolder: folderId)
        await loadSources()
        if selectedFolderID != nil { await loadItems(reset: true) }
    }

    /// Drag-and-drop result: every source's folder and order. Applied locally first, then saved.
    func reorderSources(_ order: [SourceOrderEntry]) async {
        var counters: [Int64?: Int] = [:]
        var updated = sources
        for entry in order {
            let pos = counters[entry.folderId] ?? 0
            counters[entry.folderId] = pos + 1
            if let i = updated.firstIndex(where: { $0.id == entry.id }) {
                updated[i].folderId = entry.folderId
                updated[i].position = pos
            }
        }
        sources = updated
        try? await database.reorderSources(order)
        await loadSources()
        if selectedFolderID != nil { await loadItems(reset: true) }
    }

    /// New folder at the bottom; `withSource` moves that source into it ("New folder with this").
    @discardableResult
    func createFolder(title: String, withSource sourceId: Int64? = nil) async throws -> Folder {
        let f = try await database.createFolder(title: title, withSource: sourceId)
        await loadSources()
        return f
    }

    func renameFolder(id: Int64, title: String) async throws {
        try await database.renameFolder(id: id, title: title)
        await loadSources()
    }

    /// Delete a folder; its sources move to No Folder.
    func deleteFolder(id: Int64) async throws {
        try await database.deleteFolder(id: id)
        collapsedFolders.remove(String(id))
        if selectedFolderID == id { goHome() }
        await loadSources()
    }

    /// New folder order, top to bottom. Applied locally first.
    func reorderFolders(_ ids: [Int64]) async {
        for (i, id) in ids.enumerated() {
            if let j = folders.firstIndex(where: { $0.id == id }) { folders[j].position = i }
        }
        try? await database.reorderFolders(ids)
        await loadSources()
    }

    /// New topic order, top to bottom. Applied locally first.
    func reorderTopics(_ ids: [Int64]) async {
        topicStore.applyOrder(ids)
        try? await database.reorderTopics(ids)
        await topicStore.reload()
    }

    // MARK: Topics

    /// Opens the Topic sheet for a new topic (Feed ▸ New Topic…, the sidebar's +), starting from `options`.
    func beginNewTopic(_ options: TopicOptions = TopicOptions(keyword: "")) {
        topicEditor = .new(options)
    }

    func beginEditTopic(_ topic: Source) {
        topicEditor = .edit(topic)
    }

    /// Follows a keyword: stores the topic, selects it (`select`) and searches it right away, in the
    /// background, so its list fills in. Following one that exists returns it unchanged. `notify` turns
    /// Notify on New Matches on once that first search is done, so the matches already out there don't all alert.
    @discardableResult
    func createTopic(_ options: TopicOptions, notify: Bool = false, select: Bool = true) async throws -> Source {
        if notify { try await requireNotificationAccess() }
        let topic = try await database.createTopic(options)
        await topicStore.reload()
        if select { navigate(sourceID: topic.id) }
        Task { await self.refreshTopic(id: topic.id, enableNotify: notify && !topic.notifies) }
        return topic
    }

    /// Explore's Follow: a topic for the query with the default options, left unselected.
    func followTopic(query: String) async throws {
        try await createTopic(TopicOptions(keyword: query), select: false)
    }

    /// The topic whose keyword is this Explore query, if followed.
    func topic(matching query: String) -> Source? { topicStore.topic(matching: query) }

    /// Saves the sheet's edit. A changed keyword or place searches again (the old matches that no longer
    /// fit are already gone); a changed keyword also restarts Notify on New Matches, so the new keyword's
    /// existing matches don't all alert.
    func updateTopic(id: Int64, options: TopicOptions, notify: Bool) async throws {
        if notify { try await requireNotificationAccess() }
        let before = topicStore.topic(id: id)
        let topic = try await database.updateTopic(id: id, options: options)
        await topicStore.reload()
        if notify != topic.notifies { try await database.setSourceNotify(id: id, on: notify) }
        await topicStore.reload()
        await loadItems(reset: true)
        let changed = before?.topicOptions != topic.topicOptions
        if changed {
            let rearm = notify && before?.topicKeyword != topic.topicKeyword
            Task { await self.refreshTopic(id: id, enableNotify: rearm, deliver: !rearm) }
        }
    }

    func deleteTopic(id: Int64) async throws {
        try await database.deleteTopic(id: id)
        closeTabs { $0.source.id == id }
        if selectedSourceID == id { goHome() }
        await topicStore.reload()
        await loadItems(reset: true)
    }

    /// Searches one topic now. It doesn't wait for or block a refresh of everything: a topic that was just made
    /// or edited should fill in at once.
    func refreshTopic(id: Int64, enableNotify: Bool = false, deliver: Bool = true) async {
        topicStore.setRefreshing(id, true)
        defer { topicStore.setRefreshing(id, false) }
        _ = try? await services.refresh.refreshSource(id: id)
        if deliver { await PostNotifications.deliver(database) }
        if enableNotify {
            // Off and on again: turning it on while it is on keeps the old start time.
            _ = try? await database.setSourceNotify(id: id, on: false)
            _ = try? await database.setSourceNotify(id: id, on: true)
        }
        await topicStore.reload()
        await loadItems(reset: true)
    }

    /// Opens one outlet's article of a story row (the "+N" list), as a list click would: `show` receives the article. Opening it
    /// also reads the story's lead, since the story counts as read once its lead is. Without the article stored (a retention
    /// sweep between) it opens in the browser.
    func openOutlet(_ outlet: TopicOutlet, of lead: FeedItem, show: @escaping @MainActor (FeedItem) -> Void) {
        Task {
            guard let item = try? await database.feedItem(id: outlet.id) else {
                if let url = URL(string: outlet.url) { ReaderWebSupport.openExternally(url) }
                return
            }
            history.setRead(lead, true)
            show(item)
        }
    }

    /// Opens a story's Hacker News thread in the reader, as a pasted link would be (the thread's page, not the story it links
    /// to), and reads the story's lead. The browser opens it if the page can't be stored.
    func openDiscussion(_ discussion: TopicDiscussion, of lead: FeedItem, show: @escaping @MainActor (FeedItem) -> Void) {
        Task {
            history.setRead(lead, true)
            guard let item = try? await services.openLink(discussion.url) else {
                if let url = URL(string: discussion.url) { ReaderWebSupport.openExternally(url) }
                return
            }
            show(item)
        }
    }

    /// Mark All as Read for a topic that may not be the open list (the sidebar's menu).
    func markAllRead(topic: Source) {
        let query = ItemQuery(sourceId: topic.id)
        Task { try? await database.markAllRead(query) }
    }

    /// A filter of the title menu's Show section.
    func setTopicFilter(_ filter: TopicContentFilter) {
        guard isTopicSelected, filter != topicFilter else { return }
        topicFilter = filter
        Task { await loadItems(reset: true) }
    }

    // MARK: iCloud sync

    private func startSync() async {
        // The database copy is what syncs. Only rewrite it when the settings differ, so a copy from a
        // newer version (with fields this one doesn't know) isn't stripped and sent back. Awaited, so
        // it lands before the first fetch can bring in another device's settings.
        let stored = try? await database.meta(MetaKey.syncedSettings)
        if stored.flatMap(AppSettings.init(syncJSON:)) != settings {
            try? await database.setMeta(MetaKey.syncedSettings, settings.syncJSON)
        }
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        let previous = syncToggle, on = syncEnabled, sync = sync!
        syncToggle = Task {
            await previous?.value
            await sync.setEnabled(on)
        }
    }

    /// Fetch and send now (app came to the foreground).
    func syncNow() async {
        await sync.syncNow()
    }

    private func fetchSyncedSources(_ ids: [Int64]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for id in ids { _ = try? await services.refresh.refreshSource(id: id) }
        isRefreshing = false
        await reloadAll()
    }

    private func mirrorSettingsForSync() {
        let json = settings.syncJSON
        Task { try? await database.setMeta(MetaKey.syncedSettings, json) }
    }

    private func handleSync(_ event: CloudSyncEvent) async {
        switch event {
        case .status(let s):
            syncStatus = s
        case .applied(let r):
            if let json = r.settingsJSON, let s = AppSettings(syncJSON: json), s != settings {
                applyingSyncedSettings = true
                settings = s
                applyingSyncedSettings = false
            }
            if r.integrationsChanged { await loadIntegrations() }
            guard r.libraryChanged else { return }
            await loadSources()
            await topicStore.reload()
            if let id = selectedSourceID, !sources.contains(where: { $0.id == id }), !topicStore.ids.contains(id) { goHome() }
            if let id = selectedFolderID, !folders.contains(where: { $0.id == id }) { goHome() }
            await loadItems(reset: true)
            // Sources added on another device have no items here yet. In a task of its own, since this
            // runs inside the sync engine's event handling.
            if !r.addedSourceIDs.isEmpty {
                Task { await self.fetchSyncedSources(r.addedSourceIDs) }
            }
        }
    }

    // MARK: OPML

    /// Import an OPML file the user picked (security-scoped URL from .fileImporter).
    func importOPML(from url: URL) async throws -> OPMLImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let result = try await services.importOPML(xml: xml)
        await loadSources()
        return result
    }

    /// The whole subscription list as OPML text (for .fileExporter).
    func exportOPML() async throws -> String {
        try await services.exportOPML()
    }

    /// Suggested export file name: opendispatch-YYYY-MM-DD.opml.
    static func opmlFileName(now: Date = Date()) -> String {
        "opendispatch-\(String(ISO8601.string(from: now).prefix(10))).opml"
    }

    // MARK: Integrations

    func loadIntegrations() async {
        integrations = (try? await services.integrations.state()) ?? integrations
    }

    func setReadwiseToken(_ token: String?) async throws {
        integrations = try await services.integrations.setReadwiseToken(token)
    }

    func setWebhookURL(_ url: String?) async throws {
        integrations = try await services.integrations.setWebhookURL(url)
    }

    func send(_ item: FeedItem, to target: SendTarget) async throws {
        try await services.integrations.send(item, to: target)
    }

    func testIntegration(_ target: SendTarget) async throws {
        try await services.integrations.test(target)
    }

    // MARK: Search

    /// Open the field and focus it (`/`). The view focuses its own TextField when this flips to true.
    func openSearch() { isSearchOpen = true }

    /// Empty the field and drop the query, keeping it open.
    func clearSearch() {
        searchDraft = ""
        commitSearch("")
    }

    /// Empty and close.
    func closeSearch() {
        clearSearch()
        isSearchOpen = false
    }

    /// Commit the draft now (Enter) instead of waiting out the debounce.
    func flushSearch() {
        commitSearch(searchDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func scheduleSearchCommit() {
        searchTask?.cancel()
        let next = String(searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ItemQuery.maxQueryLength))
        guard next != searchQuery else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.commitSearch(next)
        }
    }

    private func commitSearch(_ q: String) {
        searchTask?.cancel()
        let next = String(q.prefix(ItemQuery.maxQueryLength))
        guard next != searchQuery else { return }
        searchQuery = next
        // Drop the opened item so tablet/desktop shows the first result.
        setActiveItem(nil)
        Task { await loadItems(reset: true) }
    }

    private func resetSearchState() {
        searchTask?.cancel()
        if !searchDraft.isEmpty { searchDraft = "" }
        searchTask?.cancel()
        searchQuery = ""
        isSearchOpen = false
    }

    // MARK: Layout actions

    func toggleSidebar() { sidebarCollapsed.toggle() }

    func toggleFocusMode() { focusMode.toggle() }

    /// Esc: close an open sidebar filter, else an open search, else leave the full-screen reader.
    func escape() {
        if isSourceFilterOpen { closeSourceFilter() } else if isSearchOpen { closeSearch() } else { focusMode = false }
    }

    /// Show the sidebar (if hidden) and open its source filter; the field focuses itself when this flips.
    func openSourceFilter() {
        sidebarCollapsed = false
        isSourceFilterOpen = true
        sourceFilterFocusRequests += 1
    }

    /// Empty the filter and close it, restoring the tree.
    func closeSourceFilter() {
        sourceFilter = ""
        isSourceFilterOpen = false
    }

    // MARK: Reader tabs and split view

    /// List click: show the item in the focused pane. A tab that already has it comes forward (in
    /// either pane); otherwise it replaces the active tab.
    func open(_ item: FeedItem) {
        openItems[item.id] = item
        for p in [focusedPane, 1 - focusedPane] where panes.indices.contains(p) {
            if let t = panes[p].tabs.firstIndex(where: { $0.itemID == item.id }) {
                activateTab(pane: p, index: t)
                return
            }
        }
        setActiveItem(item.id)
    }

    /// ⌘-click: a new tab after the active one in the focused pane (or the tab that has it already).
    func openInNewTab(_ item: FeedItem) {
        let p = focusedPane
        if let t = panes[p].tabs.firstIndex(where: { $0.itemID == item.id }) {
            panes[p].active = t
            return
        }
        // A new tab takes the item itself rather than staying empty behind it.
        if panes[p].activeTab.isNew {
            open(item)
            return
        }
        settleFocusedTab()
        openItems[item.id] = item
        let at = max(panes[p].active + 1, panes[p].pinnedCount)
        panes[p].tabs.insert(ReaderTab(itemID: item.id), at: at)
        panes[p].active = at
    }

    /// ⌥-click: show the item in the other pane, opening split view if it is closed.
    func openInSplit(_ item: FeedItem) {
        settleFocusedTab()
        openItems[item.id] = item
        if isSplit {
            focusedPane = 1 - focusedPane
            open(item)
            return
        }
        sidebarCollapsedBeforeSplit = sidebarCollapsed
        sidebarCollapsed = true
        panes.append(ReaderPane(tabs: [ReaderTab(itemID: item.id)]))
        focusedPane = 1
    }

    /// Split view on (the item after the current one goes on the right) or off (the focused pane stays).
    func toggleSplit() {
        if isSplit {
            closePane(1 - focusedPane)
            return
        }
        guard let current = selectedItem else { return }
        let next = items.firstIndex { $0.id == current.id }.flatMap { $0 + 1 < items.count ? items[$0 + 1] : nil }
        openInSplit(next ?? current)
    }

    /// Close one pane of a split with its tabs; the sidebar comes back if the split hid it.
    func closePane(_ pane: Int) {
        guard isSplit, panes.indices.contains(pane) else { return }
        let hadPins = panes[pane].pinnedCount > 0
        panes.remove(at: pane)
        if hadPins { savePinnedTabs() }
        focusedPane = 0
        if let was = sidebarCollapsedBeforeSplit { sidebarCollapsed = was }
        sidebarCollapsedBeforeSplit = nil
        pruneOpenItems()
    }

    func focusPane(_ pane: Int) {
        guard pane != focusedPane, panes.indices.contains(pane) else { return }
        settleFocusedTab()
        focusedPane = pane
    }

    func activateTab(pane: Int, index: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        settleFocusedTab()
        focusedPane = pane
        panes[pane].active = index
    }

    /// + / ⌘T: an empty tab after the active one in the focused pane; the next item opened fills it.
    func openNewTab() {
        let p = focusedPane
        settleFocusedTab()
        let at = max(panes[p].active + 1, panes[p].pinnedCount)
        panes[p].tabs.insert(ReaderTab(isNew: true), at: at)
        panes[p].active = at
    }

    /// ⌘L: the focused pane's New Tab page with its address field focused, opening a new tab unless
    /// one is showing.
    func openLocation() {
        if !panes[focusedPane].activeTab.isNew { openNewTab() }
        addressFocusRequests += 1
    }

    /// The New Tab page's address field: the link fills that tab once it is stored (OpenedLinks). Its
    /// page is read for a title first, so meanwhile the tab shows the host with a spinner. Returns what
    /// to show under the field when the text isn't a web address or the link can't be stored.
    func openLink(_ text: String, inPane pane: Int) async -> String? {
        guard panes.indices.contains(pane), panes[pane].activeTab.isNew else { return nil }
        let url: String
        do {
            url = try SourceURL.normalize(text)
        } catch {
            return "Enter a web address, like example.com/article"
        }
        let tabID = panes[pane].activeTab.id
        func locate() -> (Int, Int)? {
            for p in panes.indices {
                if let t = panes[p].tabs.firstIndex(where: { $0.id == tabID && $0.isNew && $0.openingURL == url }) { return (p, t) }
            }
            return nil
        }
        panes[pane].tabs[panes[pane].active].openingURL = url
        let opened: FeedItem
        do {
            opened = try await services.openLink(url)
        } catch {
            if let (p, t) = locate() { panes[p].tabs[t].openingURL = nil }
            return HTTP.message(error)
        }
        // The tab was closed, or something else was opened in it, while the page loaded.
        guard let (p, t) = locate() else { return nil }
        openItems[opened.id] = opened
        panes[p].tabs[t].itemID = opened.id
        panes[p].tabs[t].isNew = false
        panes[p].tabs[t].openingURL = nil
        return nil
    }

    /// An Explore result, once stored (`ExploreStore.open`), shown from the New Tab page `tabID`: it fills
    /// that tab like a link typed in the address field, or with `inNewTab` (⌘-click) opens in a tab after it
    /// and leaves the page, with its results, where it was. A tab that already has the item comes forward
    /// instead. If the tab was closed or filled meanwhile, the item opens in a new tab.
    func openExplored(_ item: FeedItem, tabID: UUID, inNewTab: Bool) {
        for p in panes.indices {
            if let t = panes[p].tabs.firstIndex(where: { $0.itemID == item.id }) {
                activateTab(pane: p, index: t)
                return
            }
        }
        openItems[item.id] = item
        var found: (pane: Int, tab: Int)?
        for p in panes.indices {
            if let t = panes[p].tabs.firstIndex(where: { $0.id == tabID && $0.isNew }) { found = (p, t) }
        }
        guard let (p, t) = found else {
            openInNewTab(item)
            return
        }
        settleFocusedTab()
        focusedPane = p
        if inNewTab {
            let at = max(t + 1, panes[p].pinnedCount)
            panes[p].tabs.insert(ReaderTab(itemID: item.id), at: at)
            panes[p].active = at
        } else {
            panes[p].active = t
            panes[p].tabs[t].itemID = item.id
            panes[p].tabs[t].isNew = false
            panes[p].tabs[t].openingURL = nil
        }
    }

    /// Pin or unpin a tab. Pinning fixes the tab's item and moves it to the end of the pins; unpinning
    /// moves it to just after them. A new, empty tab can't be pinned.
    func togglePinned(pane: Int, index: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        var tab = panes[pane].tabs[index]
        if !tab.isPinned {
            guard let item = item(for: tab) else { return }
            openItems[item.id] = item
            tab.itemID = item.id
        }
        tab.isPinned.toggle()
        var moved = panes[pane]
        let activeID = moved.activeTab.id
        moved.tabs.remove(at: index)
        moved.tabs.insert(tab, at: moved.pinnedCount)
        moved.active = moved.tabs.firstIndex { $0.id == activeID } ?? 0
        panes[pane] = moved
        savePinnedTabs()
    }

    /// ⇧⌘T: the most recently closed tab's item, in a new tab (or the empty one that's showing).
    func reopenClosedTab() {
        guard !closedItems.isEmpty else { return }
        openInNewTab(closedItems.removeFirst())
    }

    /// Close a tab. A pane's last tab closes the pane in split view, else becomes a new, empty tab.
    func closeTab(pane: Int, index: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        rememberClosed(panes[pane].tabs[index])
        let wasPinned = panes[pane].tabs[index].isPinned
        defer { if wasPinned { savePinnedTabs() } }
        if panes[pane].tabs.count == 1 {
            if isSplit { closePane(pane) } else { panes[pane].tabs[0] = ReaderTab(isNew: true) }
            pruneOpenItems()
            return
        }
        var closed = panes[pane]
        closed.removeTab(at: index)
        panes[pane] = closed
        pruneOpenItems()
    }

    func closeOtherTabs(pane: Int, index: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        let keep = panes[pane].tabs[index]
        for (t, tab) in panes[pane].tabs.enumerated().reversed() where t != index && !tab.isPinned { rememberClosed(tab) }
        var rest = panes[pane]
        rest.tabs.removeAll { !$0.isPinned && $0.id != keep.id }
        rest.active = rest.tabs.firstIndex { $0.id == keep.id } ?? 0
        panes[pane] = rest
        pruneOpenItems()
    }

    /// Close the unpinned tabs after this one. The tab itself comes forward if the active one closed.
    func closeTabsToRight(pane: Int, index: Int) {
        guard canCloseTabsToRight(pane: pane, index: index) else { return }
        let keep = panes[pane].tabs[index].id
        let activeID = panes[pane].activeTab.id
        for tab in panes[pane].tabs[(index + 1)...].reversed() where !tab.isPinned { rememberClosed(tab) }
        var rest = panes[pane]
        rest.tabs = rest.tabs.enumerated().filter { $0.offset <= index || $0.element.isPinned }.map(\.element)
        rest.active = rest.tabs.firstIndex { $0.id == activeID } ?? rest.tabs.firstIndex { $0.id == keep } ?? 0
        panes[pane] = rest
        pruneOpenItems()
    }

    /// Whether an unpinned tab sits after this one (Close Tabs to the Right).
    func canCloseTabsToRight(pane: Int, index: Int) -> Bool {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return false }
        return panes[pane].tabs[(index + 1)...].contains { !$0.isPinned }
    }

    /// Split to Right / Move to the Other Pane. With one pane the tab opens a new right pane (the
    /// sidebar folds away as for ⌥-click) and the left pane gets a new tab if it was the only one.
    /// In a split the tab lands after the other pane's active tab (a pinned tab among that pane's pins)
    /// and is shown there, or the tab that has its item comes forward instead. A pane left without
    /// tabs closes with the split. Focus follows the tab.
    func moveTab(pane: Int, index: Int, toPane dest: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        guard dest == (isSplit ? 1 - pane : 1) else { return }
        settleFocusedTab()
        let tab = panes[pane].tabs[index]
        let wasLast = panes[pane].tabs.count == 1
        if !isSplit {
            sidebarCollapsedBeforeSplit = sidebarCollapsed
            sidebarCollapsed = true
            takeTab(pane: pane, index: index, orNew: true)
            panes.append(ReaderPane(tabs: [tab]))
            focusedPane = 1
        } else {
            let same = tab.itemID.flatMap { id in panes[dest].tabs.firstIndex { $0.itemID == id } }
            if let same {
                panes[dest].active = same
            } else {
                let at = tab.isPinned ? panes[dest].pinnedCount : max(panes[dest].active + 1, panes[dest].pinnedCount)
                panes[dest].tabs.insert(tab, at: at)
                panes[dest].active = at
            }
            if wasLast {
                closePane(pane)
            } else {
                takeTab(pane: pane, index: index, orNew: false)
                focusedPane = dest
            }
        }
        if tab.isPinned { savePinnedTabs() }
        pruneOpenItems()
    }

    /// Take a tab out of a pane; the pane then shows the tab closeTab would show (a new tab if it was the only one).
    private func takeTab(pane: Int, index: Int, orNew: Bool) {
        if panes[pane].tabs.count == 1 {
            if orNew { panes[pane].tabs[0] = ReaderTab(isNew: true) }
            return
        }
        var taken = panes[pane]
        taken.removeTab(at: index)
        panes[pane] = taken
    }

    /// Left and right trade places; the focus stays on the same content.
    func swapPanes() {
        guard isSplit else { return }
        panes.swapAt(0, 1)
        focusedPane = 1 - focusedPane
        splitFraction = 1 - splitFraction
        savePinnedTabs()
    }

    /// Combine Panes: the other pane's tabs join this one (those whose item it already has are dropped,
    /// pinned tabs stay at the front), then the split closes. This pane keeps showing its active tab.
    func combinePanes(into pane: Int) {
        guard isSplit, panes.indices.contains(pane) else { return }
        settleFocusedTab()
        let other = 1 - pane
        let activeID = panes[pane].activeTab.id
        var tabs = panes[pane].tabs
        var have = Set(tabs.compactMap(\.itemID))
        for tab in panes[other].tabs {
            if let id = tab.itemID, !have.insert(id).inserted { continue }
            tabs.append(tab)
        }
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        panes[pane] = ReaderPane(tabs: tabs, active: tabs.firstIndex { $0.id == activeID } ?? 0)
        closePane(other)
    }

    /// A tab dropped on the other pane (or on the right half of a lone pane, which splits).
    func dropTab(_ drag: ReaderTabDrag, toPane dest: Int) {
        tabDrag = nil
        guard panes.indices.contains(drag.pane),
              let index = panes[drag.pane].tabs.firstIndex(where: { $0.id == drag.tabID }) else { return }
        moveTab(pane: drag.pane, index: index, toPane: dest)
    }

    /// ⌃⌘←: the focused tab goes to the left pane.
    var canMoveTabLeft: Bool { isSplit && focusedPane == 1 }

    /// ⌃⌘→: the focused tab goes to the right pane, opening split view if it is closed.
    var canMoveTabRight: Bool { !isSplit || focusedPane == 0 }

    /// The focused pane's active tab to the other pane (`toRight` true: right pane, splitting if needed).
    func moveActiveTab(toRight: Bool) {
        guard toRight ? canMoveTabRight : canMoveTabLeft else { return }
        moveTab(pane: focusedPane, index: panes[focusedPane].active, toPane: toRight ? 1 : 0)
    }

    /// ⌘W: close the focused tab (or pane). Returns false when there is only the one tab, so the
    /// caller closes the window instead. A pinned tab stays: ⌘W shows the first unpinned tab, or a
    /// new one.
    func closeActiveTab() -> Bool {
        let p = focusedPane
        if panes[p].activeTab.isPinned {
            if panes[p].pinnedCount < panes[p].tabs.count { panes[p].active = panes[p].pinnedCount } else { openNewTab() }
            return true
        }
        guard hasReaderTabs else { return false }
        closeTab(pane: p, index: panes[p].active)
        return true
    }

    /// ⇧⌘] / ⇧⌘[: the next or previous tab in the focused pane, wrapping around.
    func selectTab(offset: Int) {
        let p = focusedPane
        let count = panes[p].tabs.count
        guard count > 1 else { return }
        settleFocusedTab()
        panes[p].active = ((panes[p].active + offset) % count + count) % count
    }

    /// The focused pane's active tab shows `id` (nil: the list's first item). A pinned tab keeps its
    /// item: `id` opens in a new tab after the pins.
    private func setActiveItem(_ id: Int64?) {
        let p = focusedPane
        if panes[p].activeTab.isPinned {
            guard let id, id != panes[p].activeTab.itemID else { return }
            let at = panes[p].pinnedCount
            panes[p].tabs.insert(ReaderTab(itemID: id), at: at)
            panes[p].active = at
            return
        }
        let t = panes[p].active
        panes[p].tabs[t].itemID = id
        panes[p].tabs[t].isNew = false
        panes[p].tabs[t].openingURL = nil
        pruneOpenItems()
    }

    /// Keep a closing tab's item for ⇧⌘T (newest first, at most 20, no repeats).
    private func rememberClosed(_ tab: ReaderTab) {
        guard let item = item(for: tab) else { return }
        closedItems.removeAll { $0.id == item.id }
        closedItems.insert(item, at: 0)
        if closedItems.count > 20 { closedItems.removeLast() }
    }

    /// Pinned items, every pane's in order, for the next launch.
    private func savePinnedTabs() {
        let ids = panes.flatMap { $0.tabs.filter(\.isPinned).compactMap(\.itemID) }
        UserDefaults.standard.set(ids.map(NSNumber.init(value:)), forKey: Keys.pinnedTabs)
    }

    /// Launch: the pinned items from last time, as pinned tabs ahead of the reader's first tab (in one
    /// pane; split view is not restored). Items that no longer exist are dropped.
    private func restorePinnedTabs() async {
        let ids = (UserDefaults.standard.array(forKey: Keys.pinnedTabs) as? [NSNumber])?.map(\.int64Value) ?? []
        guard !ids.isEmpty else { return }
        var tabs: [ReaderTab] = []
        for id in ids {
            guard let item = try? await database.feedItem(id: id) else { continue }
            openItems[id] = item
            tabs.append(ReaderTab(itemID: id, isPinned: true))
        }
        // One change, so the restored pins aren't recorded as opened.
        var pane = panes[0]
        pane.tabs.insert(contentsOf: tabs, at: 0)
        pane.active += tabs.count
        panes[0] = pane
        if tabs.count != ids.count { savePinnedTabs() }
    }

    /// A tab that follows the list's first item keeps that item once focus or the active tab moves
    /// away, so later navigation in another tab does not change it.
    private func settleFocusedTab() {
        let p = focusedPane, t = panes[p].active
        guard panes[p].tabs[t].itemID == nil, let first = item(for: panes[p].tabs[t]) else { return }
        openItems[first.id] = first
        // Shown by default, not picked: settling it isn't opening it (recordShownItems).
        shownItemIDs.insert(first.id)
        panes[p].tabs[t].itemID = first.id
    }

    /// Close every tab whose item matches (a removed source); panes keep at least one tab.
    private func closeTabs(where match: (FeedItem) -> Bool) {
        for p in panes.indices.reversed() {
            for t in panes[p].tabs.indices.reversed() {
                // Closing a pane's last tab closes the pane in split view.
                guard panes.indices.contains(p), panes[p].tabs.indices.contains(t) else { break }
                if let it = item(for: panes[p].tabs[t]), panes[p].tabs[t].itemID != nil, match(it) {
                    closeTab(pane: p, index: t)
                }
            }
        }
        closedItems.removeAll(where: match)
    }

    private func pruneOpenItems() {
        let keep = openItemIDs
        if openItems.keys.contains(where: { !keep.contains($0) }) {
            openItems = openItems.filter { keep.contains($0.key) }
        }
    }

    /// Full-screen reader is in effect only while an item is shown.
    var isFocused: Bool { focusMode && selectedItem != nil }

    /// Opens Settings on `tab`: the sheet on iOS/iPad, the overlay in the main window on macOS.
    func showSettings(_ tab: SettingsTab = .sources) {
        settingsTab = tab
        isSettingsPresented = true
    }
}

/// Settings panes: the web's four (settings-dialog.tsx) plus the native Data and About panes.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sources, appearance, themes, reader, playback, notifications, integrations, data, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sources: "Sources"
        case .appearance: "Appearance"
        case .themes: "Themes"
        case .reader: "Reader"
        case .playback: "Playback"
        case .notifications: "Notifications"
        case .integrations: "Integrations"
        case .data: "Data"
        case .about: "About"
        }
    }
}

extension ItemQuery {
    /// The list this query shows: the query apart from Hide Read Items' cutoff, which a refresh moves without
    /// changing lists.
    var listIdentity: ItemQuery {
        var q = self
        if q.hideReadBefore != nil { q.hideReadBefore = .distantPast }
        return q
    }
}
