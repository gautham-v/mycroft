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
///   in the focused pane. The context menu offers the same two, plus Open Original, Save, a Share submenu
///   and Go to <source>. The selected row is the focused pane's
///   item, the other pane's item gets a lighter highlight, and rows open in a background tab show a dot.
/// - Scrolls to the top when the view/source/folder/search changes, and keeps the highlighted row
///   visible when it moves (keyboard).
/// - Keyboard shortcuts (KeyboardShortcuts.swift) are attached here.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    #endif
    @FocusState private var searchFocused: Bool
    /// Which row the pointer is over. A reference the rows observe themselves (`HoverTracking`), not
    /// `@State` here: hover changes constantly while scrolling (rows slide under a still pointer), and
    /// state on this view re-evaluated the whole list body, every row's menu included, each time.
    @State private var hover = RowHover()
    /// Id of the list's first row while it is on screen (the list is scrolled to the top). Only read in
    /// `onChange` handlers, so it lives in a plain reference: as `@State` its first change on scrolling
    /// away from the top re-evaluated the whole list.
    @State private var topRow = TopRowTracker()
    /// iPhone: the tab this instance lives in, learned on first appearance (TabView keeps every tab
    /// alive, so only the instance of the active tab may push the reader).
    @State private var homeTab: PhoneTab?
    /// A Send to from the row menu failed: the message, shown in an alert.
    @State private var sendError: String?

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
            .alert("Couldn’t send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
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
                } else if showsBrand {
                    ToolbarItem(placement: .topBarLeading) {
                        FeedBrand()
                    }
                    .sharedBackgroundVisibility(.hidden)
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

    /// The Feed tab's home list leads with the app's logo and name.
    private var showsBrand: Bool {
        (homeTab ?? .feed) == .feed && !model.isInSourceFeed
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

    /// The body reads only the items and whether more pages exist. Selection, open tabs and loading
    /// state are read by the rows and small views that show them: whatever this body reads makes List
    /// re-diff every row when it changes, which on j/k was every key press.
    private var list: some View {
        let items = model.items
        let prefetchFrom = max(0, items.count - Self.prefetchRows)
        return ScrollViewReader { proxy in
            List {
                if items.isEmpty { ListStateRows() }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let previous = index > 0 ? items[index - 1].id : nil
                    row(item, previousID: previous)
                        .onAppear {
                            if index == 0 { topRow.id = item.id }
                            if index >= prefetchFrom { Task { await model.loadMore() } }
                        }
                        .onDisappear {
                            if topRow.id == item.id { topRow.id = nil }
                        }
                }
                if model.nextCursor != nil {
                    ListSentinel(page: items.count)
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
                guard let new, let old, old != new, topRow.id == old else { return }
                topRow.id = new
                proxy.scrollTo(new, anchor: .top)
            }
            .background { HighlightFollower(proxy: proxy) }
        }
    }

    private func row(_ item: FeedItem, previousID: Int64?) -> some View {
        RowMarks(id: item.id, previousID: previousID) { marks in
            HoverTracking(hover: hover, id: item.id, previousID: previousID) { hovered, previousHovered in
                Button(action: { open(item) }) {
                    ItemRowView(item: item, isSelected: marks.selected, isSecondary: marks.secondary,
                                isOpenInTab: marks.openInTab, isHovered: hovered, isPhone: isPhone)
                        .equatable()
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    // Inset hairline above the row, hidden around the selected, secondary or hovered row.
                    if marks.divider && !hovered && !previousHovered {
                        Rectangle()
                            .fill(Color.ofHairline)
                            .frame(height: 1)
                            .padding(.horizontal, Metrics.rowPaddingH)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .rowContextMenu(enabled: !isPhone) { RowMenu(item: item, sendError: $sendError) }
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
}

/// Skeleton, error and empty states (only when there are no rows). A view of its own so the list body
/// doesn't read `isLoading`, which flips on every view change.
private struct ListStateRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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

    private var emptyState: some View {
        VStack(spacing: 4) {
            if !model.searchQuery.isEmpty {
                Text("No results for \u{201C}\(model.searchQuery)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Searched titles, summaries, authors and full text in \(model.listTitle)")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else if model.sources.isEmpty {
                // First run: nothing is preinstalled, so the empty list is the way in.
                Text("Add your first sources")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Sites, newsletters, YouTube channels and podcasts")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                Button {
                    model.isAddSourcePresented = true
                } label: {
                    HStack(spacing: 8) {
                        OFIcon.search.image
                            .font(.system(size: 13))
                        Text("Search by name, or paste a link")
                            .font(OFFont.ui(14))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.ofFaint)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 300, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.ofBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .accessibilityLabel("Add sources")
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
}

/// Bottom of a list with more pages: "Loading..." while fetching. Re-keyed per page (`page` is the row
/// count) so it fires `onAppear` again if it is still on screen after a page lands. Reads
/// `isLoadingMore` itself so a page load doesn't re-diff the list twice more.
private struct ListSentinel: View {
    let page: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.isLoadingMore ? "Loading..." : " ")
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .plainListRow()
            .id("sentinel-\(page)")
            .onAppear { Task { await model.loadMore() } }
    }
}

/// Keeps the highlighted row visible when it moves (keyboard), without the list body reading it.
private struct HighlightFollower: View {
    let proxy: ScrollViewProxy
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .onChange(of: model.highlightedItemID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
    }
}

/// How the list marks a row.
private struct RowMarkState {
    /// The focused pane's item.
    var selected: Bool
    /// The other pane's item in split view.
    var secondary: Bool
    /// Open in a background tab.
    var openInTab: Bool
    /// The hairline above the row (hidden around the selected and secondary rows).
    var divider: Bool
}

/// A row's selection-dependent part, read per row so moving the selection re-evaluates the rows on
/// screen instead of the whole list (like `HoverTracking` for hover).
private struct RowMarks<Content: View>: View {
    let id: Int64
    let previousID: Int64?
    @ViewBuilder let content: (RowMarkState) -> Content
    @Environment(AppModel.self) private var model

    var body: some View {
        let highlighted = model.highlightedItemID
        let secondaryID = model.secondaryHighlightedItemID
        let selected = id == highlighted
        let secondary = id == secondaryID
        content(RowMarkState(
            selected: selected,
            secondary: secondary,
            openInTab: !selected && !secondary && model.openItemIDs.contains(id),
            divider: previousID != nil && !selected && !secondary && previousID != highlighted && previousID != secondaryID))
    }
}

/// Which row the pointer is over (macOS / iPad pointer).
@MainActor @Observable private final class RowHover {
    var id: Int64?
}

/// The first row on screen. Deliberately not observable.
private final class TopRowTracker {
    var id: Int64?
}

/// A row's hover-dependent part, so a hover change re-evaluates the rows on screen that read it (the
/// hovered row, and the one below it for its divider) instead of the whole list.
private struct HoverTracking<Content: View>: View {
    let hover: RowHover
    let id: Int64
    let previousID: Int64?
    /// Receives whether this row, and the row above it, is hovered.
    @ViewBuilder let content: (_ hovered: Bool, _ previousHovered: Bool) -> Content

    var body: some View {
        let current = hover.id
        content(current == id, previousID != nil && current == previousID)
            .onHover { inside in
                if inside { hover.id = id } else if hover.id == id { hover.id = nil }
            }
    }
}

/// The row's context menu: where to open it, Save, Share (the reader's Share menu as a submenu), then the
/// source's feed. A view of its own so it is built when the menu opens, not for every row on every
/// evaluation of the list (it reads `model.integrations` and `model.selectedSourceID`, which would also
/// make the list depend on them).
private struct RowMenu: View {
    let item: FeedItem
    @Binding var sendError: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let url = URL(string: item.item.url)
        Button("Open in New Tab") { model.openInNewTab(item) }
        Button("Open in Split View") { model.openInSplit(item) }
        if let url {
            Button("Open Original") { openURL(url) }
        }
        Divider()
        Button(item.isSaved ? "Remove from Saved" : "Save") { Task { await model.toggleSaved(item) } }
        if let url {
            Menu("Share") {
                ShareLink(item: url, subject: Text(item.item.title), message: Text(item.item.title)) {
                    Text("Share…")
                }
                Button("Copy Link") { ReaderPasteboard.copy(url) }
                Button("Copy as Markdown") { model.copyMarkdown(item: item) }
                Divider()
                let targets = model.integrations.configuredTargets
                if targets.isEmpty {
                    Button("Set Up Send To…") { model.showSettings(.integrations) }
                } else {
                    ForEach(targets) { t in
                        Button("Send to \(SendToView.menuLabel(t))") { send(to: t) }
                    }
                }
            }
        }
        if model.selectedSourceID != item.source.id, !item.source.isOpenedLinks {
            Divider()
            Button("Go to \(item.source.title)") { model.navigate(sourceID: item.source.id) }
        }
    }

    private func send(to target: SendTarget) {
        Task {
            do {
                try await model.send(item, to: target)
            } catch {
                sendError = HTTP.message(error)
            }
        }
    }
}

#if os(iOS)
/// The app's logo and name at the top of the iPhone Feed tab.
private struct FeedBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("OpenDispatch")
                .font(OFFont.ui(20, .semibold))
                .tracking(-0.3)
                .foregroundStyle(.ofInk)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenDispatch")
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

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
