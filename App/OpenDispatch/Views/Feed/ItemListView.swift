import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The item list column. Port of the list parts of src/components/openfeed-app.tsx and use-data.ts
/// (paging lives in AppModel).
///
/// - macOS / iPad (regular width): 54pt desktop header, rows without snippets. On macOS the column runs
///   flush to the window edges (like the Claude desktop app); the split view draws the column dividers.
/// - iPhone (compact): no header or title; the system navigation bar carries a filter menu (content
///   type + hn100/labs/blogs) and the `.searchable` search item; headline-only rows; pull to refresh.
///   Opening a row pushes `ReaderView` onto this tab's NavigationStack.
/// - States: skeleton while the first page loads, error with Retry, empty / no-results messages.
/// - Infinite scroll: rows near the end and a trailing sentinel call `model.loadMore()`.
/// - Row click (macOS): ⌘ opens in a new reader tab, ⌥ in the other pane of the split view, otherwise
///   in the focused pane. The context menu offers the same two. The selected row is the focused pane's
///   item, the other pane's item gets a lighter highlight, and rows open in a background tab show a dot.
/// - Scrolls to the top when the view/source/folder/search changes, and keeps the highlighted row
///   visible when it moves (keyboard).
/// - Keyboard shortcuts (KeyboardShortcuts.swift) are attached here.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    #endif
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: Int64?
    /// Id of the list's first row while it is on screen (the list is scrolled to the top).
    @State private var visibleTopID: Int64?
    /// iPhone: the tab this instance lives in, learned on first appearance (TabView keeps every tab
    /// alive, so only the instance of the active tab may push the reader).
    @State private var homeTab: PhoneTab?

    /// Rows within this many of the end trigger the next page (≈ the web's 600px rootMargin).
    private static let prefetchRows = 8

    private var isPhone: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        column
            .feedKeyboardShortcuts(searchFocus: $searchFocused)
            .onChange(of: model.isSearchOpen) { _, open in
                // ⌘F (menu) and `/` open the field; focus it once it is on screen.
                if open {
                    Task { @MainActor in
                        await Task.yield()
                        searchFocused = true
                    }
                } else {
                    searchFocused = false
                }
            }
    }

    // MARK: Layout

    @ViewBuilder private var column: some View {
        #if os(iOS)
        if isPhone {
            phoneColumn
        } else {
            desktopColumn
        }
        #else
        desktopColumn
        #endif
    }

    /// The rows scroll under the header, which is frosted. An overlay plus a top content inset rather
    /// than a safe-area inset: List clips its rows to the safe area on macOS.
    private var desktopColumn: some View {
        list
            .topContentInset(Self.headerHeight)
            .overlay(alignment: .top) {
                DesktopListHeader(searchFocus: $searchFocused)
            }
            .background(Color.ofSurface)
    }

    /// DesktopListHeader's height, the gap under it included.
    private static var headerHeight: CGFloat {
        #if os(macOS)
        Metrics.topBarHeight + Metrics.listHeaderGap
        #else
        Metrics.desktopHeaderHeight
        #endif
    }

    #if os(iOS)
    /// iPhone: the list alone under the system navigation bar (no title text), so it scrolls under the
    /// Liquid Glass bars. Toolbar: filter menu + search; pull to refresh.
    private var phoneColumn: some View {
        @Bindable var model = model
        return list
            .refreshable { await model.refresh(force: true) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                if showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: backToSources) {
                            Label("Back to sources", systemImage: OFIcon.back.rawValue)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    FeedFilterMenu(showsContentTypes: showsContentTypes)
                }
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            }
            .searchable(text: $model.searchDraft, isPresented: searchPresented, prompt: Text(model.searchPlaceholder))
            .searchToolbarBehavior(.minimize)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { model.flushSearch() }
            .onAppear { if homeTab == nil { homeTab = model.phoneTab } }
            .navigationDestination(isPresented: readerPresented) {
                ReaderView()
            }
    }

    /// The content-type section of the filter menu: Feed tab only (not a source/folder feed, not Saved),
    /// like the web's `tab === "feed"` chips.
    private var showsContentTypes: Bool {
        !model.isInSourceFeed && model.selectedView != .saved && (homeTab ?? .feed) == .feed
    }

    /// A source/folder feed shown at the root of a tab (opened from Settings) has no system back button.
    /// Pushed from the Sources tab it does, and SourcesView handles the pop.
    private var showsBackButton: Bool {
        model.isInSourceFeed && (homeTab ?? model.phoneTab) != .sources
    }

    private func backToSources() {
        if model.phoneTab == .sources {
            dismiss()
            model.goHome()
        } else {
            model.phoneTab = .sources
        }
    }

    /// Search presentation for this tab's instance only (TabView keeps every tab's list alive).
    private var searchPresented: Binding<Bool> {
        Binding(
            get: { model.isSearchOpen && (homeTab == nil || homeTab == model.phoneTab) },
            set: { open in
                if open { model.openSearch() } else if model.isSearchOpen { model.closeSearch() }
            })
    }

    private var readerPresented: Binding<Bool> {
        Binding(
            get: { model.selectedItemID != nil && (homeTab == nil || homeTab == model.phoneTab) },
            set: { presented in
                if !presented, model.selectedItemID != nil { model.select(nil) }
            })
    }
    #endif

    // MARK: List

    private var list: some View {
        let items = model.items
        let prefetchFrom = max(0, items.count - Self.prefetchRows)
        let highlighted = model.highlightedItemID
        let secondaryID = model.secondaryHighlightedItemID
        let openIDs = model.openItemIDs
        return ScrollViewReader { proxy in
            List {
                stateRows
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let selected = item.id == highlighted
                    let secondary = item.id == secondaryID
                    let hovered = item.id == hoveredID
                    let openInTab = !selected && !secondary && openIDs.contains(item.id)
                    let previous = index > 0 ? items[index - 1].id : nil
                    // Inset hairline above the row, hidden around the selected, secondary or hovered row.
                    let divider = previous != nil && !selected && !secondary && !hovered
                        && previous != highlighted && previous != secondaryID && previous != hoveredID
                    row(item, selected: selected, secondary: secondary, openInTab: openInTab, hovered: hovered, divider: divider)
                        .onAppear {
                            if index == 0 { visibleTopID = item.id }
                            if index >= prefetchFrom { Task { await model.loadMore() } }
                        }
                        .onDisappear {
                            if visibleTopID == item.id { visibleTopID = nil }
                        }
                }
                if model.nextCursor != nil {
                    sentinel
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .overlayScrollers()
            .background(Color.ofSurface)
            .environment(\.defaultMinListRowHeight, 1)
            .onChange(of: model.currentQuery) { _, _ in
                // The old list stays up while the next one loads; start the new one at the top.
                if let first = model.items.first { proxy.scrollTo(first.id, anchor: .top) }
            }
            .onChange(of: model.items.first?.id) { old, new in
                // New items arrived above (a refresh finished): if the list was at the top, stay at the
                // top instead of keeping the old first row anchored in place.
                guard let new, let old, old != new, visibleTopID == old else { return }
                visibleTopID = new
                proxy.scrollTo(new, anchor: .top)
            }
            .onChange(of: model.highlightedItemID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ item: FeedItem, selected: Bool, secondary: Bool, openInTab: Bool, hovered: Bool, divider: Bool) -> some View {
        Button(action: { open(item) }) {
            ItemRowView(item: item, isSelected: selected, isSecondary: secondary, isOpenInTab: openInTab,
                        isHovered: hovered, isPhone: isPhone)
                .equatable()
        }
        .buttonStyle(.plain)
        .rowContextMenu(enabled: !isPhone) {
            Button("Open in New Tab") { model.openInNewTab(item) }
            Button("Open in Split View") { model.openInSplit(item) }
        }
        .overlay(alignment: .top) {
            if divider {
                Rectangle()
                    .fill(Color.ofHairline)
                    .frame(height: 1)
                    .padding(.leading, Metrics.rowDividerInset)
                    .padding(.trailing, Metrics.rowPaddingH)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .onHover { inside in
            if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .plainListRow()
        .id(item.id)
    }

    /// Row click: ⌘ opens a new tab, ⌥ opens the other pane (macOS), otherwise the focused pane.
    private func open(_ item: FeedItem) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            model.openInNewTab(item)
        } else if flags.contains(.option) {
            model.openInSplit(item)
        } else {
            model.open(item)
        }
        #else
        model.open(item)
        #endif
    }

    /// Skeleton, error and empty states (only when there are no rows).
    @ViewBuilder private var stateRows: some View {
        if model.items.isEmpty {
            if model.isLoading {
                ForEach(0..<8, id: \.self) { _ in
                    ItemSkeletonRow()
                        .padding(.horizontal, 8)
                        .plainListRow()
                }
            } else if model.loadError != nil {
                HStack(spacing: 4) {
                    Text("Could not load items.")
                        .foregroundStyle(.ofMuted)
                    Button("Retry") { Task { await model.loadItems(reset: true) } }
                        .buttonStyle(.plain)
                        .fontWeight(.medium)
                        .underline()
                        .foregroundStyle(.ofAccent)
                }
                .font(OFFont.ui(14))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 64)
                .plainListRow()
            } else {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 64)
                    .plainListRow()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            if !model.searchQuery.isEmpty {
                Text("No results for \u{201C}\(model.searchQuery)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Searched titles, summaries, authors and full text in \(model.listTitle)")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else {
                Text(model.selectedView == .saved && !model.isInSourceFeed ? "Nothing saved yet" : "Nothing here yet")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("No items in this view")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Bottom of a list with more pages: "Loading..." while fetching. Re-keyed per page so it fires
    /// `onAppear` again if it is still on screen after a page lands.
    private var sentinel: some View {
        Text(model.isLoadingMore ? "Loading..." : " ")
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .plainListRow()
            .id("sentinel-\(model.items.count)")
            .onAppear { Task { await model.loadMore() } }
    }
}

private extension View {
    /// A context menu on the desktop layouts only (the iPhone row has none).
    @ViewBuilder func rowContextMenu<Menu: View>(enabled: Bool, @ViewBuilder _ menu: () -> Menu) -> some View {
        if enabled { contextMenu(menuItems: menu) } else { self }
    }

    /// Full-bleed list row: no insets, separators or system background (rows draw their own).
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    let model = AppModel.preview()
    return ItemListView()
        .environment(model)
        .frame(width: 410, height: 700)
        .task { await model.loadItems() }
}
