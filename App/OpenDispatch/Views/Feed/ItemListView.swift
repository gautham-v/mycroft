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
    @Environment(\.isFeedStackPushed) private var isFeedStackPushed
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
    /// iPhone: this is the stack's home list (the drawer's views and folders), not a source's feed pushed
    /// from Manage sources, which SourcesView creates with the default.
    var isPhoneHome = false
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
    /// iPhone: the list with its title as the first row and the glass bubbles along the bottom (see
    /// `phoneListChrome`). The home list has no navigation bar; a source's feed pushed from Manage sources
    /// keeps the system one (transparent) for its back button. Pull to refresh. Swiping sideways slides
    /// the list (`PhonePageOffset`) but not the bubbles.
    private var phoneColumn: some View {
        list
            .refreshable { await model.refresh(force: true) }
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
        return ScrollViewReader { proxy in
            List {
                #if os(iOS)
                if isPhone {
                    // Press and hold the title for the list's read actions (the Mac has them in the title menu).
                    PhoneTitleRow()
                        .contextMenu {
                            Button("Mark All as Read", systemImage: "checkmark.circle") { model.markAllRead() }
                                .disabled(items.isEmpty)
                            Toggle(isOn: Binding(get: { model.settings.hideReadItems }, set: { _ in model.toggleHideReadItems() })) {
                                Label("Hide Read Items", systemImage: "eye.slash")
                            }
                        }
                        .tint(Color.ofInk)
                }
                #endif
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
                scrollToTop(proxy, firstID: model.items.first?.id)
            }
            .onChange(of: model.items.first?.id) { old, new in
                // New items arrived above (a refresh finished): if the list was at the top, stay at the
                // top instead of keeping the old first row anchored in place.
                guard let new, let old, old != new, topRow.id == old else { return }
                topRow.id = new
                scrollToTop(proxy, firstID: new)
            }
            .background { HighlightFollower(proxy: proxy) }
        }
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
                Button(action: { open(item) }) {
                    ItemRowView(item: item, isSelected: marks.selected, isSecondary: marks.secondary,
                                isOpenInTab: marks.openInTab, isHovered: hovered, isPhone: isPhone,
                                isRead: marks.read, progress: marks.progress)
                        .equatable()
                }
                .buttonStyle(.plain)
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
        .plainListRow()
        .id(item.id)
    }

    /// Row click: ⌘ opens a new tab, ⌥ opens the other pane (macOS), otherwise the focused pane.
    private func open(_ item: FeedItem) {
        #if os(iOS)
        if PhoneDrawerTouch.blocksRowTap { return }
        #endif
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
    /// Read (History), and a video or episode's progress.
    var read: Bool
    var progress: Double?
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
            progress: entry?.progress))
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
            Button("Go to \(item.source.title)", systemImage: "dot.radiowaves.up.forward") { model.navigate(sourceID: item.source.id) }
        }
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
