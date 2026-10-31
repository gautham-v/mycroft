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
/// - iPhone (compact): no header or top bar; the list's title is its first row (32pt, scrolls away) and
///   floating Liquid Glass bubbles sit over the rows along the bottom: the drawer's hamburger at the leading
///   edge, page dots in the middle (the five content views), search at the trailing edge. A source's feed
///   pushed from Manage sources has the system back button at the top and only the search bubble.
///   Headline-only rows; pull to refresh. Opening a row pushes `ReaderView` onto the PhoneRoot stack;
///   pressing and holding one lifts it with a menu (Save, Share…, Copy Link / Markdown, Open in Browser,
///   Send To, Go to <source>).
/// - States: skeleton while the first page loads, error with Retry, empty / no-results messages.
/// - Infinite scroll: rows near the end and a trailing sentinel call `model.loadMore()`.
/// - macOS lists the rows in a `LazyVStack` rather than a `List` (see `RowStack`).
/// - Row click (macOS): ⌘ opens in a new reader tab, ⌥ in the other pane of the split view, otherwise
///   in the focused pane. The context menu offers the same two, plus Open Original, Save, a Share submenu
///   and Go to <source>. The selected row is the focused pane's
///   item, the other pane's item gets a lighter highlight, and rows open in a background tab show a dot.
/// - Scrolls to the top when the view/source/folder/search changes, and keeps the highlighted row
///   visible when it moves (keyboard).
/// - Rows a refresh adds above the ones on screen don't push them down: what's on screen stays put and a pill over
///   the top of the list says "↑ 4 new" (`NewRowsPill`), counting down as they scroll into view; clicking it scrolls
///   to the top. Pull to refresh on iPhone shows them at the top instead.
/// - Keyboard shortcuts (KeyboardShortcuts.swift) are attached here.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isFeedStackPushed) private var isFeedStackPushed
    #endif
    @FocusState private var searchFocused: Bool
    /// Which row the pointer is over. A reference the rows observe themselves (`HoverTracking`), not
    /// `@State` here: hover changes constantly while scrolling (rows slide under a still pointer), and
    /// state on this view re-evaluated the whole list body, every row's menu included, each time.
    @State private var hover = RowHover()
    /// New rows above the screen, for the pill; only the pill reads them.
    @State private var newRows = NewRows()
    #if os(macOS)
    /// Whether the list is scrolled to the very top. Only read in `onChange` handlers, so it lives in a plain
    /// reference: as `@State` its change on scrolling away from the top would re-evaluate the whole list.
    @State private var scrollEdge = ScrollEdge()
    #else
    /// Keeps the rows on screen in place when rows land above them (List doesn't).
    @State private var listAnchor = ListAnchor()
    #endif
    /// iPhone: this is the stack's home list (the drawer's views and folders), not a source's feed pushed
    /// from Manage sources, which SourcesView creates with the default.
    var isPhoneHome = false
    /// A Send to from the row menu failed: the message, shown in an alert.
    @State private var sendError: String?
    /// A Notify on New Matches change from a topic's title menu failed (iPhone; the Mac's title menu has its own).
    @State private var topicNotifyError: String?

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
            .topicNotifyAlert($topicNotifyError)
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
            .modifier(MutedListContentInset(base: Self.headerHeight))
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
    /// iPhone: the list with its title as the first row and the glass bubbles along the bottom (see
    /// `phoneListChrome`). The home list has no navigation bar; a source's feed pushed from Manage sources
    /// keeps the system one (transparent) for its back button. Pull to refresh. Swiping sideways slides
    /// the list (`PhonePageOffset`) but not the bubbles.
    private var phoneColumn: some View {
        list
            .refreshable {
                // Pulling down asks for the new rows, so they show at the top rather than behind the pill.
                newRows.reveal(until: .distantFuture)
                listAnchor.reveal(until: .distantFuture)
                await model.refresh(force: true)
                let end = Date().addingTimeInterval(1)
                newRows.reveal(until: end)
                listAnchor.reveal(until: end)
            }
            .modifier(PhonePageOffset(isHome: isPhoneHome))
            .background(Color.ofSurface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isPhoneHome ? .hidden : .automatic, for: .navigationBar)
            .phoneListChrome(isHome: isPhoneHome, showsBubbles: isFrontmost)
            .navigationDestination(isPresented: readerPresented) {
                ReaderView()
            }
    }

    /// Whether this list is the one this screen is showing: the home list while nothing is pushed above it,
    /// else the source's feed pushed from Manage sources. Both stay alive in the stack, and only the
    /// visible one may push the reader.
    private var isFrontmost: Bool { isPhoneHome != isFeedStackPushed }

    private var readerPresented: Binding<Bool> {
        Binding(
            get: { model.selectedItemID != nil && isFrontmost },
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
        #if os(iOS)
        listAnchor.expect(items.map(\.id))
        listAnchor.leadingRows = isPhone ? 1 : 0
        listAnchor.isPaused = model.isStartHereList
        #endif
        return ScrollViewReader { proxy in
            RowStack {
                #if os(iOS)
                if isPhone {
                    // `isPhoneHome`, not `isPhone`: the iPad's list column is compact too, and has the board beside it.
                    if isPhoneHome && model.startHereFillsList {
                        StartHereListRow()
                    } else {
                        // Press and hold the title for the list's read actions (the Mac has them in the title menu).
                        PhoneTitleRow()
                            .contextMenu {
                                if let topic = model.activeTopic {
                                    TopicListMenuItems(topic: topic, error: $topicNotifyError)
                                } else {
                                    Button("Mark All as Read", systemImage: "checkmark.circle") { model.markAllRead() }
                                        .disabled(items.isEmpty)
                                }
                                Toggle(isOn: Binding(get: { model.settings.hideReadItems }, set: { _ in model.toggleHideReadItems() })) {
                                    Label("Hide Read Items", systemImage: "eye.slash")
                                }
                            }
                            .tint(Color.ofInk)
                    }
                }
                listRows(items, prefetchFrom: prefetchFrom)
                #else
                listRows(items, prefetchFrom: prefetchFrom)
                #endif
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .overlayScrollers()
            .background(Color.ofSurface)
            .environment(\.defaultMinListRowHeight, 1)
            #if os(macOS)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y <= -$0.contentInsets.top + 0.5 } action: { _, top in
                scrollEdge.atTop = top
            }
            .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.5) { ids in
                newRows.scrolled(toFirstOf: ids, in: model.items)
            }
            #else
            .background { ListAnchorFinder(anchor: listAnchor) }
            .onAppear {
                listAnchor.onTopRow = { [newRows, model] id in newRows.scrolled(toTop: id, in: model.items) }
            }
            #endif
            .onChange(of: model.currentQuery.listIdentity) { _, _ in
                // The old list stays up while the next one loads; start the new one at the top. (A refresh moves
                // Hide Read Items' cutoff, which isn't another list.)
                newRows.clear()
                scrollToTop(proxy, firstID: model.items.first?.id)
            }
            .onChange(of: model.items.map(\.id)) { old, new in
                #if os(macOS)
                // SwiftUI keeps the rows on screen in place when rows land above them, except at the very top,
                // where it keeps the top edge: put the old first row back at the top.
                // (Not while the Start here board is up: the list is filling for the first time.)
                if scrollEdge.atTop, !model.isStartHereUp, let first = old.first, first != new.first, new.contains(first) {
                    proxy.scrollTo(first, anchor: .top)
                }
                #else
                listAnchor.itemsChanged()
                #endif
            }
            .onChange(of: model.arrivedItemIDs) { _, ids in
                newRows.arrived(ids, in: model.items)
            }
            .overlay(alignment: .top) {
                NewRowsPill(rows: newRows, isPhone: isPhone) {
                    newRows.clear()
                    withAnimation(.smooth(duration: 0.35)) { scrollToTop(proxy, firstID: model.items.first?.id) }
                }
                .padding(.top, pillTop)
                .modifier(MutedListPillInset(isPhone: isPhone))
            }
            .background { HighlightFollower(proxy: proxy) }
        }
    }

    /// The pill's place: under the desktop header, or on iPhone under the status bar's fade.
    private var pillTop: CGFloat {
        isPhone ? 10 : Self.headerHeight + 8
    }

    /// The list's states and rows, with the sentinel that pages in the next ones.
    @ViewBuilder private func listRows(_ items: [FeedItem], prefetchFrom: Int) -> some View {
        if items.isEmpty && model.hiddenPaywalledCount == 0 && model.hiddenBlockedVideoCount == 0 { ListStateRows(boardAbove: isPhoneHome && model.startHereFillsList) }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let previous = index > 0 ? items[index - 1].id : nil
            ListRow(item: item, previousID: previous, isPhone: isPhone) { row(item, previousID: previous) }
                .equatable()
                // Outside the equatable wrapper: List doesn't see row traits set inside it, and drew its own
                // insets and separators around every row.
                .plainListRow()
                .onAppear {
                    if index >= prefetchFrom { Task { await model.loadMore() } }
                }
        }
        if model.nextCursor != nil {
            // The page that loaded may be all hidden, so the sentinel is keyed by what was loaded, not by what shows.
            ListSentinel(page: items.count + model.hiddenPaywalledCount)
        }
        PaywallFooter()
        BlockedVideosFooter()
    }

    /// Back to the top: the first row, or on the iPhone the title above it.
    private func scrollToTop(_ proxy: ScrollViewProxy, firstID: Int64?) {
        #if os(iOS)
        if isPhone {
            proxy.scrollTo(PhoneTitleRow.id, anchor: .top)
            return
        }
        #endif
        if let firstID { proxy.scrollTo(firstID, anchor: .top) }
    }

    private func row(_ item: FeedItem, previousID: Int64?) -> some View {
        RowMarks(item: item, previousID: previousID) { marks in
            HoverTracking(hover: hover, id: item.id, previousID: previousID) { hovered, previousHovered in
                rowContent(item, marks: marks, hovered: hovered)
                    .overlay(alignment: .top) {
                        // Inset hairline above the row, hidden around the selected, secondary or hovered row.
                        if marks.divider && !hovered && !previousHovered {
                            Rectangle()
                                .fill(Color.ofHairline)
                                .frame(height: 1)
                                .padding(.horizontal, isPhone ? Metrics.phoneRowPaddingH : Metrics.rowPaddingH)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8)
            }
        }
        .contextMenu { RowMenu(item: item, isPhone: isPhone, sendError: $sendError) }
        // iPhone: the menu's icons and labels in ink, like the drawer, rather than the accent blue.
        .tint(isPhone ? Color.ofInk : nil)
        .id(item.id)
    }

    /// The row itself: a button, or for a topic's news story (other outlets or a discussion behind it) a `StoryRowView`,
    /// whose outlets and discussion chip are buttons of their own.
    @ViewBuilder private func rowContent(_ item: FeedItem, marks: RowMarkState, hovered: Bool) -> some View {
        if item.story != nil {
            StoryRowView(item: item, isSelected: marks.selected, isSecondary: marks.secondary, isOpenInTab: marks.openInTab,
                         isHovered: hovered, isPhone: isPhone, isRead: marks.read, paywall: marks.paywall,
                         actions: StoryRowActions(
                            openLead: { open(item) },
                            openOutlet: { outlet in openOutlet(outlet, of: item) },
                            openDiscussion: { openDiscussion(of: item) }))
                .equatable()
        } else {
            Button(action: { open(item) }) {
                ItemRowView(item: item, isSelected: marks.selected, isSecondary: marks.secondary,
                            isOpenInTab: marks.openInTab, isHovered: hovered, isPhone: isPhone,
                            isRead: marks.read, progress: marks.progress, showsTopic: model.selectedSourceID != item.source.id,
                            paywall: marks.paywall, opensOnYouTube: marks.opensOnYouTube)
                    .equatable()
            }
            .buttonStyle(.plain)
        }
    }

    /// How a click opens: in the focused pane, or with ⌘ in a new tab and ⌥ in the other pane (macOS).
    private enum OpenMode { case focused, newTab, split }

    private static var openMode: OpenMode {
        #if os(macOS)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return .newTab }
        if flags.contains(.option) { return .split }
        #endif
        return .focused
    }

    private func show(_ item: FeedItem, _ mode: OpenMode) {
        switch mode {
        case .focused: model.open(item)
        case .newTab: model.openInNewTab(item)
        case .split: model.openInSplit(item)
        }
    }

    /// Row click: ⌘ opens a new tab, ⌥ opens the other pane (macOS), otherwise the focused pane, or YouTube for a video that
    /// won't play here. ⌘ and ⌥ ask for the reader, so they get it, with its notice.
    private func open(_ item: FeedItem) {
        #if os(iOS)
        if PhoneDrawerTouch.blocksRowTap { return }
        #endif
        let mode = Self.openMode
        if mode == .focused, model.opensOnYouTube(item) {
            model.watchOnYouTube(item)
        } else {
            show(item, mode)
        }
    }

    /// A click on one outlet of a story's expanded list: that article opens like a row would, and the lead is read.
    private func openOutlet(_ outlet: TopicOutlet, of lead: FeedItem) {
        #if os(iOS)
        if PhoneDrawerTouch.blocksRowTap { return }
        #endif
        let mode = Self.openMode
        model.openOutlet(outlet, of: lead) { show($0, mode) }
    }

    /// A click on a story's Hacker News chip: the thread opens in the reader.
    private func openDiscussion(of lead: FeedItem) {
        #if os(iOS)
        if PhoneDrawerTouch.blocksRowTap { return }
        #endif
        guard let discussion = lead.story?.discussion else { return }
        let mode = Self.openMode
        model.openDiscussion(discussion, of: lead) { show($0, mode) }
    }
}

/// Skeleton, error and empty states (only when there are no rows). A view of its own so the list body
/// doesn't read `isLoading`, which flips on every view change.
private struct ListStateRows: View {
    /// The Start here board is the list's first row, and says it all.
    let boardAbove: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if boardAbove {
            EmptyView()
        } else if model.isLoading && !model.isStartHereList {
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
            } else if let topic = model.activeTopic {
                topicEmptyState(topic)
            } else if model.isStartHereList {
                // First run: nothing is preinstalled, and the Start here board beside the list is the way in.
                Text("Add something and its stories appear here.")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else if model.selectedView != .saved, let source = model.activeSource, let error = source.lastError {
                Text("Couldn\u{2019}t refresh \u{201C}\(source.title)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text(error)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else if model.selectedView != .saved, let source = model.activeSource, source.lastFetchedAt == nil {
                Text("Loading \u{201C}\(source.title)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
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

    /// An empty topic: still searching its first time, why it found nothing, or that nothing matched yet.
    @ViewBuilder private func topicEmptyState(_ topic: Source) -> some View {
        if model.topicStore.refreshing.contains(topic.id) || topic.lastFetchedAt == nil {
            Text("Searching for \u{201C}\(topic.title)\u{201D}")
                .font(OFFont.ui(15, .medium))
                .foregroundStyle(.ofInk)
            Text("Matches from the last two weeks appear here")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
        } else if let error = topic.lastError {
            Text("Couldn\u{2019}t search for \u{201C}\(topic.title)\u{201D}")
                .font(OFFont.ui(15, .medium))
                .foregroundStyle(.ofInk)
            Text(error)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
        } else {
            Text(model.topicFilter == .all ? "No matches yet" : "No \(model.topicFilter.title.lowercased()) yet")
                .font(OFFont.ui(15, .medium))
                .foregroundStyle(.ofInk)
            Text("New matches show up here after each refresh")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
        }
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

/// The list's last row when it hides articles from paywalled sites: how many, and Show to see them until you leave the list.
private struct PaywallFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.hiddenPaywalledCount
        if count > 0 {
            HiddenRowsNote(text: "\(count) hidden from sites you don\u{2019}t subscribe to \u{00B7}") { model.showHiddenPaywalled() }
        }
    }
}

/// The same when it hides videos that won't play here.
private struct BlockedVideosFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.hiddenBlockedVideoCount
        if count > 0 {
            HiddenRowsNote(text: "\(count) hidden that won\u{2019}t play here \u{00B7}") { model.showHiddenBlockedVideos() }
        }
    }
}

private struct HiddenRowsNote: View {
    let text: String
    let show: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(.ofMuted)
            Button("Show", action: show)
                .buttonStyle(.plain)
                .foregroundStyle(.ofAccent)
        }
        .font(OFFont.ui(13))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .plainListRow()
        .accessibilityElement(children: .combine)
    }
}

/// Keeps the highlighted row visible when it moves (keyboard), without the list body reading it.
private struct HighlightFollower: View {
    let proxy: ScrollViewProxy
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .onChange(of: model.highlightedItemID) { _, id in
                // Only an opened item: the default tab's first row changes when a refresh adds rows above it,
                // which mustn't pull the list up to them.
                guard let id, model.panes[model.focusedPane].activeTab.itemID != nil else { return }
                proxy.scrollTo(id)
            }
    }
}

/// One row as the list builds it, re-evaluated with the list only when its item, the row above it or the layout
/// changes. What else a row shows (selection, hover, read state, the theme) it observes itself, so without this every
/// row the stack had built re-ran its body each time `items` changed, e.g. a page loading mid-scroll.
private struct ListRow<Content: View>: View, Equatable {
    let item: FeedItem
    let previousID: Int64?
    let isPhone: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    nonisolated static func == (a: ListRow, b: ListRow) -> Bool {
        a.item == b.item && a.previousID == b.previousID && a.isPhone == b.isPhone
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
    /// Read (History), and a video or episode's progress.
    var read: Bool
    var progress: Double?
    /// The site wants a subscription and the setting marks it (see `ItemRowView.paywall`).
    var paywall: PaywallStatus
    /// A video that won't play here and the setting marks it (see `ItemRowView.opensOnYouTube`).
    var opensOnYouTube: Bool
}

/// A row's selection-dependent part, read per row so moving the selection re-evaluates the rows on
/// screen instead of the whole list (like `HoverTracking` for hover).
private struct RowMarks<Content: View>: View {
    let item: FeedItem
    let previousID: Int64?
    private var id: Int64 { item.id }
    @ViewBuilder let content: (RowMarkState) -> Content
    @Environment(AppModel.self) private var model

    var body: some View {
        let highlighted = model.highlightedItemID
        let secondaryID = model.secondaryHighlightedItemID
        let selected = id == highlighted
        let secondary = id == secondaryID
        let entry = model.history.entry(for: item)
        content(RowMarkState(
            selected: selected,
            secondary: secondary,
            openInTab: !selected && !secondary && model.openItemIDs.contains(id),
            divider: previousID != nil && !selected && !secondary && previousID != highlighted && previousID != secondaryID,
            read: entry?.isRead ?? false,
            progress: entry?.progress,
            paywall: model.paywallStatus(of: item),
            opensOnYouTube: model.opensOnYouTube(item)))
    }
}

/// Which row the pointer is over (macOS / iPad pointer).
@MainActor @Observable private final class RowHover {
    var id: Int64?
}

#if os(macOS)
/// Whether the list is at its very top. Deliberately not observable.
private final class ScrollEdge {
    var atTop = true
}
#endif

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
/// source's feed. On iPhone a flat menu with icons instead (`phoneMenu`). A view of its own so it is built when the menu opens, not for every row on every
/// evaluation of the list (it reads `model.integrations` and `model.selectedSourceID`, which would also
/// make the list depend on them).
private struct RowMenu: View {
    let item: FeedItem
    var isPhone = false
    @Binding var sendError: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        if isPhone { phoneMenu } else { desktopMenu }
    }

    /// iPhone (press and hold a row): flat, with icons; no tabs or split view.
    @ViewBuilder private var phoneMenu: some View {
        let url = URL(string: item.item.url)
        Button(item.isSaved ? "Remove from Saved" : "Save", systemImage: item.isSaved ? "bookmark.slash" : "bookmark") {
            Task { await model.toggleSaved(item) }
        }
        let read = model.history.isRead(item)
        Button(HistoryStore.markLabel(kind: item.source.kind, isRead: read), systemImage: read ? "circle" : "checkmark.circle") {
            model.toggleRead(item)
        }
        if let url {
            ShareLink(item: url, subject: Text(item.item.title), message: Text(item.item.title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button("Copy Link", systemImage: "link") { ReaderPasteboard.copy(url) }
            Button("Copy as Markdown", systemImage: "doc.on.doc") { model.copyMarkdown(item: item) }
            Button("Open in Browser", systemImage: "safari") { openURL(url) }
            sendMenu
        }
        if model.selectedSourceID != item.source.id, !item.source.isOpenedLinks {
            Divider()
            Button(goToTitle, systemImage: "dot.radiowaves.up.forward") { model.navigate(sourceID: item.source.id) }
        }
        MuteRowMenuItem(item: item, icons: true)
    }

    /// A topic's item goes to its topic (named by keyword); any other to its source.
    private var goToTitle: String {
        item.source.isTopic ? "Go to \(item.source.title) Topic" : "Go to \(item.source.title)"
    }

    @ViewBuilder private var sendMenu: some View {
        let targets = model.integrations.configuredTargets
        if targets.isEmpty {
            Button("Set Up Send To…", systemImage: "paperplane") { model.showSettings(.integrations) }
        } else {
            Menu {
                ForEach(targets) { t in
                    Button("Send to \(SendToView.menuLabel(t))") { send(to: t) }
                }
            } label: {
                Label("Send To", systemImage: "paperplane")
            }
        }
    }

    @ViewBuilder private var desktopMenu: some View {
        let url = URL(string: item.item.url)
        Button("Open in New Tab") { model.openInNewTab(item) }
        Button("Open in Split View") { model.openInSplit(item) }
        if let url {
            Button("Open Original") { openURL(url) }
        }
        Divider()
        Button(item.isSaved ? "Remove from Saved" : "Save") { Task { await model.toggleSaved(item) } }
        Button(HistoryStore.markLabel(kind: item.source.kind, isRead: model.history.isRead(item))) { model.toggleRead(item) }
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
            Button(goToTitle) { model.navigate(sourceID: item.source.id) }
        }
        if !item.source.isTopic, !item.source.isOpenedLinks {
            Divider()
            MuteRowMenuItem(item: item)
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

/// The rows' container. macOS: a lazy stack in a scroll view. List is an NSTableView there, and with rows of
/// varying height it lays out every inserted row up front, so each page appended while scrolling (50 rows) froze
/// the list for half a second or more. Elsewhere a plain List (pull to refresh, the iPhone's page swipes).
private struct RowStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        ScrollView {
            LazyVStack(spacing: 0) { content }
                .scrollTargetLayout()
        }
        #else
        List { content }
            .listStyle(.plain)
        #endif
    }
}

private extension View {
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
