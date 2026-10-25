import Foundation
import Observation
import OpenfeedCore

/// Phone tab bar (openfeed-app.tsx): Feed / Sources / Saved / Settings.
enum PhoneTab: String, Hashable, CaseIterable, Sendable {
    case feed, sources, saved, settings
}

/// App state and actions shared by every view. Port of the state in src/components/openfeed-app.tsx,
/// src/hooks/use-data.ts, use-search.ts and use-settings.ts. Everything is local (AppDatabase).
///
/// Navigation mirrors the web URL state: one of view / source / folder, an optional search query,
/// and an optional selected item. Changing view/source/folder clears the item and the search.
@MainActor
@Observable
final class AppModel {
    let services: OpenfeedServices
    var database: AppDatabase { services.database }

    // MARK: Navigation (read-only outside; use navigate(...))

    private(set) var selectedView: FeedView = .all
    private(set) var selectedSourceID: Int64?
    private(set) var selectedFolderID: Int64?
    /// Legacy hn100/labs/blogs filter; nil = none. Set with setFilter(_:).
    private(set) var filter: FeedFilter?
    /// The opened item. nil = nothing opened (see `selectedItem` for the default-selection rule).
    private(set) var selectedItemID: Int64?
    /// Tablet/desktop: with nothing opened, show the first item (the web app's md+ behavior). Set by RootView.
    var prefersDefaultSelection = false
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

    // MARK: Layout state

    /// Desktop sidebar hidden (⌘\). Persisted.
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }
    /// Full-screen reader (⇧⌘F): hides sidebar and list while an item is open. Session only.
    var focusMode = false
    /// Collapsed sidebar folders: folder id as a string, or "unfiled". Persisted.
    var collapsedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedFolders), forKey: Keys.collapsedFolders) }
    }

    // MARK: Presentation flags (sheets / dialogs)

    var isAddSourcePresented = false
    /// URL to prefill in the Add source sheet (deep link `openfeed://add?url=…`); the sheet clears it.
    var pendingAddSourceURL: String?
    var isShortcutsPresented = false
    /// iOS/iPad settings sheet (macOS uses the Settings scene). `settingsTab` picks the pane.
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

    /// Reader settings, theme, playback. Persisted on change.
    var settings: AppSettings {
        didSet { if settings != oldValue { settings.save() } }
    }

    // MARK: Private

    @ObservationIgnored private var loadGeneration = 0
    /// The query `nextCursor` belongs to; paging a different query from it would append wrong rows.
    @ObservationIgnored private var cursorQuery: ItemQuery?
    /// The opened item when it is not in the current page (deep link, or list reloaded under it).
    @ObservationIgnored private var pinnedItem: FeedItem?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private enum Keys {
        static let sidebarCollapsed = "openfeed.sidebar-collapsed"
        static let collapsedFolders = "openfeed.sidebar.collapsed"
    }

    init(services: OpenfeedServices) {
        self.services = services
        let defaults = UserDefaults.standard
        sidebarCollapsed = defaults.bool(forKey: Keys.sidebarCollapsed)
        collapsedFolders = Set(defaults.stringArray(forKey: Keys.collapsedFolders) ?? [])
        settings = AppSettings.load()
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
        await loadStats()
        await loadIntegrations()
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
    var listTitle: String { activeSource?.title ?? activeFolder?.title ?? selectedView.title }

    /// Search field placeholder: "Search" in All, else "Search <title>".
    var searchPlaceholder: String { listTitle == "All" ? "Search" : "Search \(listTitle)" }

    /// "updated 5m ago" / "updated just now" / "updated never".
    func updatedLabel(now: Date = Date()) -> String { RelativeTime.updatedLabel(lastRefreshAt, now: now) }

    /// The item the reader shows: the opened one, else (tablet/desktop) the first in the list.
    var selectedItem: FeedItem? {
        if let id = selectedItemID {
            return items.first { $0.id == id } ?? (pinnedItem?.id == id ? pinnedItem : nil)
        }
        return prefersDefaultSelection ? items.first : nil
    }

    /// Id the list highlights (the opened item or the default first one).
    var highlightedItemID: Int64? { selectedItem?.id }

    /// Folders in sidebar order (position, id).
    var orderedFolders: [Folder] {
        folders.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    /// Sources in a folder (nil = Unfiled) in sidebar order: position, then title.
    func sources(inFolder folderId: Int64?) -> [Source] {
        sources.filter { $0.folderId == folderId }.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

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
        selectedItemID = nil
        Task { await loadItems(reset: true) }
    }

    private func setNav(view: FeedView, source: Int64?, folder: Int64?) {
        let changed = view != selectedView || source != selectedSourceID || folder != selectedFolderID || !searchQuery.isEmpty
        selectedView = view
        selectedSourceID = source
        selectedFolderID = folder
        selectedItemID = nil
        pinnedItem = nil
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

    /// Open an item (nil closes the reader).
    func select(_ item: FeedItem?) {
        selectedItemID = item?.id
        pinnedItem = item
    }

    /// Open an item by id (deep link); loads it if it is not in the current page.
    func select(itemID: Int64) async {
        selectedItemID = itemID
        if items.contains(where: { $0.id == itemID }) { return }
        if let it = try? await database.feedItem(id: itemID), selectedItemID == itemID { pinnedItem = it }
    }

    /// j/k: select the next (1) or previous (-1) item; prefetches the next page near the end.
    func moveSelection(by step: Int) {
        guard !items.isEmpty else { return }
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
        if var p = pinnedItem, p.id == id {
            change(&p)
            pinnedItem = p
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

    /// Deep link: `openfeed://add?url=<feed or site>` opens Add source prefilled with that URL.
    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "openfeed" else { return }
        let action = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action == "add" else { return }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value
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
        if selectedSourceID == id { goHome() }
        await loadSources()
        await loadItems(reset: true)
    }

    func renameSource(id: Int64, title: String) async throws {
        try await database.renameSource(id: id, title: title)
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

    /// Suggested export file name: openfeed-YYYY-MM-DD.opml.
    static func opmlFileName(now: Date = Date()) -> String {
        "openfeed-\(String(ISO8601.string(from: now).prefix(10))).opml"
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
        selectedItemID = nil
        pinnedItem = nil
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

    /// Esc: close an open search, else leave the full-screen reader.
    func escape() {
        if isSearchOpen { closeSearch() } else { focusMode = false }
    }

    /// Full-screen reader is in effect only while an item is shown.
    var isFocused: Bool { focusMode && selectedItem != nil }

    func showSettings(_ tab: SettingsTab = .sources) {
        settingsTab = tab
        isSettingsPresented = true
    }
}

/// Settings panes (settings-dialog.tsx).
enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sources, appearance, playback, integrations
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sources: "Sources"
        case .appearance: "Appearance"
        case .playback: "Playback"
        case .integrations: "Integrations"
        }
    }
}
