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
struct ReaderTab: Identifiable, Equatable, Sendable {
    let id = UUID()
    var itemID: Int64?
    var isNew = false
    var isPinned = false
}

/// A reader column (split view has two): its tabs and the one showing.
struct ReaderPane: Equatable, Sendable {
    var tabs: [ReaderTab] = [ReaderTab()]
    var active = 0
    var activeTab: ReaderTab { tabs[active] }
    /// Pinned tabs come first, so this is also the index of the first unpinned one.
    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }
}

/// Phone tab bar (openfeed-app.tsx): Feed / Sources / Saved / Settings.
enum PhoneTab: String, Hashable, CaseIterable, Sendable {
    case feed, sources, saved, settings
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
    var database: AppDatabase { services.database }

    // MARK: Navigation (read-only outside; use navigate(...))

    private(set) var selectedView: FeedView = .all
    private(set) var selectedSourceID: Int64?
    private(set) var selectedFolderID: Int64?
    /// Legacy hn100/labs/blogs filter; nil = none. Set with setFilter(_:).
    private(set) var filter: FeedFilter?
    /// The opened item: the focused pane's active tab. nil = nothing opened (see `selectedItem` for
    /// the default-selection rule).
    var selectedItemID: Int64? { panes[focusedPane].activeTab.itemID }
    /// Tablet/desktop: with nothing opened, show the first item (the web app's md+ behavior). Set by RootView.
    var prefersDefaultSelection = false
    /// The Highlights view (sidebar, Saved tab on iPhone) is showing instead of an item list: the articles
    /// that have highlights, which HighlightStore lists. Any other navigation turns it off.
    private(set) var showsHighlights = false
    /// Phone tab. Setting it navigates like the web tab bar (Feed → All, Saved → Saved view).
    var phoneTab: PhoneTab = .feed {
        didSet { if phoneTab != oldValue { didSelectTab(phoneTab) } }
    }

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
    /// The sidebar's collapsed-by-default "Hidden (N)" group is open. Session only.
    var isHiddenGroupExpanded = false

    // MARK: Layout state

    /// Desktop sidebar hidden (⌘\). Persisted.
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }
    /// Full-screen reader (⇧⌘F): hides sidebar and list while an item is open. Session only.
    var focusMode = false
    /// Reader panes: one, or two in split view, each with its own tabs. Session only.
    private(set) var panes: [ReaderPane] = [ReaderPane()]
    /// The pane the list, j/k and the item shortcuts act on.
    private(set) var focusedPane = 0
    /// The left pane's share of the reader's width in split view.
    var splitFraction: CGFloat = 0.5
    /// Collapsed sidebar folders: folder id as a string, or "unfiled". Persisted.
    var collapsedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedFolders), forKey: Keys.collapsedFolders) }
    }

    // MARK: Presentation flags (sheets / dialogs)

    var isAddSourcePresented = false
    /// URL to prefill in the Add source sheet (deep link `opendispatch://add?url=…`); the sheet clears it.
    var pendingAddSourceURL: String?
    var isShortcutsPresented = false
    /// Settings: the sheet on iOS/iPad, the in-window overlay on macOS. `settingsTab` picks the pane.
    var isSettingsPresented = false
    var settingsTab: SettingsTab = .sources

    // MARK: Data

    private(set) var items: [FeedItem] = []
    private(set) var nextCursor: ItemCursor?
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

    /// Reader settings, theme, playback. Persisted on change, and mirrored into the database for iCloud sync.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if !applyingSyncedSettings { mirrorSettingsForSync() }
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
    @ObservationIgnored private var started = false
    @ObservationIgnored private var applyingSyncedSettings = false
    @ObservationIgnored private var syncToggle: Task<Void, Never>?
    /// Created in init; its events come back to `handleSync(_:)` on the main actor.
    @ObservationIgnored private var sync: CloudSync!

    /// UserDefaults keys keep the app's original name so existing settings carry over.
    private enum Keys {
        static let sidebarCollapsed = "openfeed.sidebar-collapsed"
        static let collapsedFolders = "openfeed.sidebar.collapsed"
        static let syncEnabled = "openfeed.icloud-sync"
        static let pinnedTabs = "openfeed.pinned-tabs"
    }

    init(services: OpenDispatchServices) {
        self.services = services
        let defaults = UserDefaults.standard
        sidebarCollapsed = defaults.bool(forKey: Keys.sidebarCollapsed)
        collapsedFolders = Set(defaults.stringArray(forKey: Keys.collapsedFolders) ?? [])
        settings = AppSettings.load()
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? true
        sync = CloudSync(database: services.database) { [weak self] event in
            await self?.handleSync(event)
        }
    }

    /// Opens the on-disk database; falls back to an in-memory one if that fails (the app still runs).
    static func live() -> AppModel {
        let db: AppDatabase
        do {
            db = try AppDatabase.openDefault()
        } catch {
            // Last resort so the UI can show something; data will not persist this session.
            db = try! AppDatabase.inMemory(seed: true)
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
        await loadSources()
        await loadItems(reset: true)
        await restorePinnedTabs()
        await loadStats()
        await loadIntegrations()
        // Not awaited: the first fetch from iCloud must not hold up the first refresh.
        Task { await startSync() }
        await refresh(force: false)
    }

    // MARK: Derived

    /// The ItemQuery for the current navigation and search.
    var currentQuery: ItemQuery {
        ItemQuery(view: selectedView, sourceId: selectedSourceID, folderId: selectedFolderID, filter: filter, search: searchQuery)
    }

    var activeSource: Source? { selectedSourceID.flatMap { id in sources.first { $0.id == id } } }
    var activeFolder: Folder? { selectedFolderID.flatMap { id in folders.first { $0.id == id } } }
    /// A source or folder feed (belongs to the Sources tab on phones).
    var isInSourceFeed: Bool { selectedSourceID != nil || selectedFolderID != nil }

    /// Header title: source title, folder title, or the view name.
    var listTitle: String { showsHighlights ? "Highlights" : activeSource?.title ?? activeFolder?.title ?? selectedView.title }

    /// Search field placeholder: "Search" in All, else "Search <title>".
    var searchPlaceholder: String { listTitle == "All" ? "Search" : "Search \(listTitle)" }

    /// "updated 5m ago" / "updated just now" / "updated never".
    func updatedLabel(now: Date = Date()) -> String { RelativeTime.updatedLabel(lastRefreshAt, now: now) }

    /// The item the reader shows: the opened one, else (tablet/desktop) the first in the list.
    var selectedItem: FeedItem? { activeItem(inPane: focusedPane) }

    /// Id the list highlights (the opened item or the default first one).
    var highlightedItemID: Int64? { selectedItem?.id }

    /// The other pane's item in split view, which the list marks more lightly.
    var secondaryHighlightedItemID: Int64? { isSplit ? activeItem(inPane: 1 - focusedPane)?.id : nil }

    /// Items open in some tab, shown or not (the list marks the ones in background tabs).
    var openItemIDs: Set<Int64> { Set(panes.flatMap { $0.tabs.compactMap(\.itemID) }) }

    var isSplit: Bool { panes.count > 1 }

    /// ⌘W closes a tab instead of the window: there's a split, more than one tab, or the one tab
    /// isn't already a new tab.
    var hasReaderTabs: Bool { isSplit || panes[0].tabs.count > 1 || !panes[0].activeTab.isNew }

    /// Items from closed tabs, most recent first (⇧⌘T, the new tab's Recently closed). Session only.
    private(set) var closedItems: [FeedItem] = []

    /// What a tab shows: its item, or with none opened (tablet/desktop) the first in the list that
    /// isn't pinned, so the default tab never repeats a pin (the newest item pinned last launch).
    func item(for tab: ReaderTab) -> FeedItem? {
        if tab.isNew { return nil }
        if let id = tab.itemID { return items.first { $0.id == id } ?? openItems[id] }
        guard prefersDefaultSelection, !showsHighlights else { return nil }
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

    /// Sources shown in a folder (nil = Unfiled) in sidebar order: position, then title. Pinned and hidden
    /// sources are listed in their own groups instead.
    func sources(inFolder folderId: Int64?) -> [Source] {
        SourceList.inFolder(sources, folderId)
    }

    /// Every source of a folder, pinned and hidden included (iPhone Sources tab, which has no such groups).
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

    // MARK: Navigation

    /// Show a view (All, Saved, Articles, ...). Clears source/folder, item and search.
    func navigate(view: FeedView) {
        setNav(view: view, source: nil, folder: nil)
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

    func setFilter(_ f: FeedFilter?) {
        guard f != filter else { return }
        filter = f
        setActiveItem(nil)
        Task { await loadItems(reset: true) }
    }

    /// Show the Highlights view: the articles with highlights, under Saved.
    func showHighlights() {
        setNav(view: .saved, source: nil, folder: nil)
        showsHighlights = true
    }

    private func setNav(view: FeedView, source: Int64?, folder: Int64?) {
        let changed = view != selectedView || source != selectedSourceID || folder != selectedFolderID || !searchQuery.isEmpty
        showsHighlights = false
        selectedView = view
        selectedSourceID = source
        selectedFolderID = folder
        setActiveItem(nil)
        resetSearchState()
        if changed { Task { await loadItems(reset: true) } }
    }

    private func didSelectTab(_ tab: PhoneTab) {
        switch tab {
        case .feed: goHome()
        case .saved: navigate(view: .saved)
        case .sources, .settings: break
        }
    }

    // MARK: Items

    /// Reload the first page for the current query (reset) or load the next page.
    func loadItems(reset: Bool = true) async {
        guard reset else { return await loadMore() }
        loadGeneration += 1
        let gen = loadGeneration
        let query = currentQuery
        isLoading = true
        do {
            let page = try await database.items(query)
            guard gen == loadGeneration else { return }
            items = page.items
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
            let seen = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !seen.contains($0.id) })
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
        if let it = try? await database.feedItem(id: itemID), selectedItemID == itemID { openItems[itemID] = it }
    }

    /// j/k: select the next (1) or previous (-1) item; prefetches the next page near the end.
    func moveSelection(by step: Int) {
        guard !items.isEmpty, !showsHighlights else { return }
        let from = selectedItem?.id
        let i = items.firstIndex { $0.id == from } ?? -1
        let target = i < 0 ? 0 : min(max(i + step, 0), items.count - 1)
        if step > 0, nextCursor != nil, i + step >= items.count - 5 { Task { await loadMore() } }
        let next = items[target]
        if next.id == from { return }
        select(next)
    }

    /// Optimistic save/unsave; reverts if the write fails.
    func toggleSaved(_ item: FeedItem) async {
        let saved = !item.isSaved
        patchLocal(item.id) { $0.item.isSaved = saved }
        do {
            try await database.setSaved(itemId: item.id, saved: saved)
            counts = (try? await database.counts()) ?? counts
        } catch {
            patchLocal(item.id) { $0.item.isSaved = !saved }
        }
    }

    /// Toggle saved on the selected item (keyboard `s`).
    func toggleSavedOnSelection() async {
        if let it = selectedItem { await toggleSaved(it) }
    }

    private func patchLocal(_ id: Int64, _ change: (inout FeedItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
        if var p = openItems[id] {
            change(&p)
            openItems[id] = p
        }
    }

    /// Reader content (cached or freshly extracted). Marks the row as having content.
    func content(for item: FeedItem, refresh: Bool = false) async throws -> ExtractResult {
        let result = try await services.content.content(forItem: item.id, refresh: refresh)
        if result.contentHtml != nil { patchLocal(item.id) { $0.hasContent = true } }
        if item.item.thumbnailUrl == nil, let lead = result.leadImage { patchLocal(item.id) { $0.item.thumbnailUrl = lead } }
        return result
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
            if force || r.ran {
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
        guard action == "add" else { return }
        let target = query?.first { $0.name == "url" }?.value
        pendingAddSourceURL = target
        isAddSourcePresented = true
    }

    /// Sources, items, counts and stats.
    func reloadAll() async {
        await loadSources()
        await loadItems(reset: true)
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

    /// Puts a digest of the scope's last `days` days on the clipboard as Markdown. `filter` is the
    /// list's hn100 / labs / blogs filter, when the digest is of what the list shows.
    func copyDigest(_ scope: DigestScope, days: Int, filter: FeedFilter? = nil) {
        let prompt = copyPrompt
        let now = Date()
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let query: ItemQuery
        switch scope {
        case .view(let v): query = ItemQuery(view: v, filter: filter)
        case .folder(let f): query = ItemQuery(folderId: f.id, filter: filter)
        case .source(let s): query = ItemQuery(sourceId: s.id, filter: filter)
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

    /// "Add source": detect the feed, insert it (or find the existing one), fetch it, then refresh everything.
    /// Throws a user-facing error (bad URL, nothing found).
    @discardableResult
    func addSource(url: String) async throws -> Source {
        let (source, _) = try await services.addSource(url: url)
        await loadSources()
        Task { await self.refresh(force: true) }
        return source
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

    /// Hide from (or show again in) the sidebar tree. Items still appear in the views.
    func setSourceHidden(id: Int64, hidden: Bool) async throws {
        try await database.setSourceHidden(id: id, hidden: hidden)
        await loadSources()
    }

    /// Move a source to a folder (nil = Unfiled), at the end of it.
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

    /// Delete a folder; its sources move to Unfiled.
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
            if let id = selectedSourceID, !sources.contains(where: { $0.id == id }) { goHome() }
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
        let activeID = panes[pane].activeTab.id
        panes[pane].tabs.remove(at: index)
        panes[pane].tabs.insert(tab, at: panes[pane].pinnedCount)
        panes[pane].active = panes[pane].tabs.firstIndex { $0.id == activeID } ?? 0
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
        panes[pane].tabs.remove(at: index)
        let active = panes[pane].active
        if index < active || active >= panes[pane].tabs.count { panes[pane].active = active - 1 }
        pruneOpenItems()
    }

    func closeOtherTabs(pane: Int, index: Int) {
        guard panes.indices.contains(pane), panes[pane].tabs.indices.contains(index) else { return }
        let keep = panes[pane].tabs[index]
        for (t, tab) in panes[pane].tabs.enumerated().reversed() where t != index && !tab.isPinned { rememberClosed(tab) }
        panes[pane].tabs.removeAll { !$0.isPinned && $0.id != keep.id }
        panes[pane].active = panes[pane].tabs.firstIndex { $0.id == keep.id } ?? 0
        pruneOpenItems()
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
        pruneOpenItems()
    }

    /// Keep a closing tab's item for ⇧⌘T and Recently closed (newest first, at most 20, no repeats).
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
        panes[0].tabs.insert(contentsOf: tabs, at: 0)
        panes[0].active += tabs.count
        if tabs.count != ids.count { savePinnedTabs() }
    }

    /// A tab that follows the list's first item keeps that item once focus or the active tab moves
    /// away, so later navigation in another tab does not change it.
    private func settleFocusedTab() {
        let p = focusedPane, t = panes[p].active
        guard panes[p].tabs[t].itemID == nil, let first = item(for: panes[p].tabs[t]) else { return }
        openItems[first.id] = first
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
    case sources, appearance, playback, integrations, data, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sources: "Sources"
        case .appearance: "Appearance"
        case .playback: "Playback"
        case .integrations: "Integrations"
        case .data: "Data"
        case .about: "About"
        }
    }
}
