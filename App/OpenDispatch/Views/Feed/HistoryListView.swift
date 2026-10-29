import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The History view: what was opened, newest first, grouped by day, built from the history table alone so it
/// lists articles this device no longer has (or never had). Rows look like the feed's, with the time each
/// was opened in place of when it was published; a video or episode left partway shows how far it got.
/// Search (the header's field, the iPhone's search bubble) matches titles and sources.
///
/// Opening a row shows it in the reader, adding the item back from the entry when it was pruned
/// (`AppModel.open(_:inNewTab:)`). Clear… asks for a range (last hour, today, today and yesterday, all), and
/// a row's menu (and on iPhone a swipe to the left) removes one entry. Either makes those articles unread.
struct HistoryListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var isClearing = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isFeedStackPushed) private var isFeedStackPushed
    #endif

    private var isPhone: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            if isPhone { phoneColumn } else { desktopColumn }
            #else
            desktopColumn
            #endif
        }
        .feedKeyboardShortcuts(searchFocus: $searchFocused)
        .onChange(of: model.isSearchOpen) { _, open in
            if open {
                Task { @MainActor in
                    await Task.yield()
                    searchFocused = true
                }
            } else {
                searchFocused = false
            }
        }
        .confirmationDialog("Clear History", isPresented: $isClearing, titleVisibility: .visible) {
            ForEach(HistoryClearRange.allCases) { range in
                Button(range.label, role: range == .all ? .destructive : nil) { model.history.clear(range) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clearing also marks these items unread\(model.syncEnabled ? " on all your devices" : "").")
        }
    }

    private var desktopColumn: some View {
        list
            .topContentInset(Self.headerHeight)
            .overlay(alignment: .top) {
                HistoryListHeader(searchFocus: $searchFocused) { isClearing = true }
            }
            .background(Color.ofSurface)
    }

    private static var headerHeight: CGFloat {
        #if os(macOS)
        Metrics.topBarHeight + Metrics.listHeaderGap
        #else
        Metrics.desktopHeaderHeight
        #endif
    }

    #if os(iOS)
    /// iPhone: the title row with Clear beside it, and the glass bubbles along the bottom like the other
    /// lists' (the drawer's hamburger and search, no page dots: History doesn't swipe between views).
    private var phoneColumn: some View {
        list
            .modifier(PhonePageOffset(isHome: true))
            .background(Color.ofSurface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .phoneListChrome(isHome: true, showsBubbles: !isFeedStackPushed)
            .navigationDestination(isPresented: Binding(
                get: { model.selectedItemID != nil && model.showsHistory && !isFeedStackPushed },
                set: { presented in if !presented, model.selectedItemID != nil { model.select(nil) } })
            ) {
                ReaderView()
            }
    }
    #endif

    /// The opened entries matching the search (every term in the title or source), grouped by day.
    private var days: [HistoryDay] {
        let terms = model.searchQuery.lowercased().split(whereSeparator: \.isWhitespace)
        let entries = model.history.opened.filter { e in
            terms.isEmpty || terms.allSatisfy { "\(e.itemTitle) \(e.originLabel)".lowercased().contains($0) }
        }
        return HistoryDay.group(entries)
    }

    private var list: some View {
        let days = days
        return List {
            #if os(iOS)
            if isPhone { phoneTitleRow }
            #endif
            if days.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 64)
                    .plainRow()
            }
            ForEach(days) { day in
                Text(day.title)
                    .font(isPhone ? OFFont.ui(15, .semibold) : OFFont.ui(12, .semibold))
                    .foregroundStyle(.ofMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isPhone ? 20 : 8 + Metrics.rowPaddingH)
                    .padding(.top, day.id == days.first?.id ? 4 : 18)
                    .padding(.bottom, 2)
                    .plainRow()
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                    HistoryRow(entry: entry, showsDivider: index > 0, isPhone: isPhone)
                        .plainRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .overlayScrollers()
        .background(Color.ofSurface)
        .environment(\.defaultMinListRowHeight, 1)
    }

    #if os(iOS)
    /// PhoneTitleRow's title, with Clear at the end of the line.
    private var phoneTitleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("History")
                .font(OFFont.ui(32, .semibold))
                .tracking(-0.7)
                .foregroundStyle(.ofInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !model.history.opened.isEmpty {
                Button("Clear") { isClearing = true }
                    .font(OFFont.ui(17))
                    .foregroundStyle(.ofInk)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(PhoneTitleRow.id)
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 4) {
            if !model.searchQuery.isEmpty {
                Text("No results for \u{201C}\(model.searchQuery)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Searched titles and sources in History")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else {
                Text("No history yet")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Articles, videos and episodes you open show up here.")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// One day of History: its heading and what was opened that day, newest first.
struct HistoryDay: Identifiable {
    let id: Date
    let title: String
    let entries: [HistoryEntry]

    /// Today, Yesterday, the weekday within the last week, then the date ("Monday, Oct 26").
    static func group(_ entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        var days: [HistoryDay] = []
        var current: (Date, [HistoryEntry])?
        for e in entries {
            guard let at = e.openedAt else { continue }
            let day = calendar.startOfDay(for: at)
            if let c = current, c.0 == day {
                current = (day, c.1 + [e])
            } else {
                if let c = current { days.append(HistoryDay(id: c.0, title: title(c.0, now: now, calendar: calendar), entries: c.1)) }
                current = (day, [e])
            }
        }
        if let c = current { days.append(HistoryDay(id: c.0, title: title(c.0, now: now, calendar: calendar), entries: c.1)) }
        return days
    }

    static func title(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if daysAgo == 1 { return "Yesterday" }
        if daysAgo < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// A History entry, drawn as the feed's row (ItemRowView) from the entry's own snapshot.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let showsDivider: Bool
    let isPhone: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    /// The entry as a list item, for ItemRowView (its source has no id here; nothing looks it up).
    private var row: FeedItem {
        let host = URLComponents(string: entry.itemUrl).flatMap { c in c.scheme.flatMap { s in c.host.map { "\(s)://\($0)" } } }
        let source = Source(title: entry.sourceTitle, url: host ?? entry.itemUrl, feedUrl: entry.sourceFeedUrl,
                            kind: entry.sourceKind, group: "")
        let item = Item(sourceId: 0, guid: entry.itemGuid, url: entry.itemUrl, title: entry.itemTitle, author: entry.itemAuthor,
                        publishedAt: entry.itemPublishedAt ?? entry.openedAt ?? Date(), thumbnailUrl: entry.thumbnailUrl,
                        videoId: entry.videoId, durationSec: entry.durationSec.map { Int($0) }, audioUrl: entry.audioUrl)
        return FeedItem(item: item, source: source)
    }

    private var isSelected: Bool {
        guard let item = model.selectedItem else { return false }
        return HistoryStore.key(for: item) == entry.key
    }

    private var time: String {
        (entry.openedAt ?? Date()).formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        let selected = isSelected
        Button(action: { open(inNewTab: newTabModifier) }) {
            ItemRowView(item: row, isSelected: selected, isHovered: hovered, isPhone: isPhone,
                        progress: entry.progress, timeText: time)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if showsDivider && !selected && !hovered {
                Rectangle()
                    .fill(Color.ofHairline)
                    .frame(height: 1)
                    .padding(.horizontal, isPhone ? Metrics.phoneRowPaddingH : Metrics.rowPaddingH)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
        .contextMenu { menu }
        .tint(isPhone ? Color.ofInk : nil)
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "trash", role: .destructive) { model.history.remove(entry) }
        }
        #endif
    }

    private var newTabModifier: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        #else
        false
        #endif
    }

    private func open(inNewTab: Bool) {
        #if os(iOS)
        if PhoneDrawerTouch.blocksRowTap { return }
        #endif
        Task { await model.open(entry, inNewTab: inNewTab) }
    }

    @ViewBuilder private var menu: some View {
        let url = URL(string: entry.itemUrl)
        let markLabel = HistoryStore.markLabel(kind: entry.sourceKind, isRead: entry.isRead)
        if isPhone {
            Button(markLabel, systemImage: entry.isRead ? "circle" : "checkmark.circle") { model.history.setRead(entry, !entry.isRead) }
            if let url {
                ShareLink(item: url, subject: Text(entry.itemTitle), message: Text(entry.itemTitle)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button("Copy Link", systemImage: "link") { ReaderPasteboard.copy(url) }
                Button("Open in Browser", systemImage: "safari") { openURL(url) }
            }
            Divider()
            Button("Remove from History", systemImage: "trash", role: .destructive) { model.history.remove(entry) }
        } else {
            Button("Open in New Tab") { open(inNewTab: true) }
            if let url { Button("Open Original") { openURL(url) } }
            Divider()
            Button(markLabel) { model.history.setRead(entry, !entry.isRead) }
            if let url { Button("Copy Link") { ReaderPasteboard.copy(url) } }
            Divider()
            Button("Remove from History") { model.history.remove(entry) }
        }
    }
}

/// The desktop list header for History: the title menu (or the search field), search, and Clear History.
private struct HistoryListHeader: View {
    @Environment(AppModel.self) private var model
    var searchFocus: FocusState<Bool>.Binding
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if model.sidebarCollapsed {
                Button(action: { model.toggleSidebar() }) {
                    OFIcon.sidebar.image
                        .font(.system(size: 15))
                        .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedHoverIconButtonStyle())
                .help("Show sidebar (\u{2318}\\)")
                .accessibilityLabel("Show sidebar")
            }
            if model.isSearchOpen {
                FeedSearchField(focus: searchFocus)
            } else {
                ListTitleMenu()
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeedSearchButton(searchFocus: searchFocus)
            }
            Button(action: clear) {
                OFIcon.trash.image
                    .font(.system(size: 15))
                    .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FeedHoverIconButtonStyle())
            .disabled(model.history.opened.isEmpty)
            .help("Clear History…")
            .accessibilityLabel("Clear History")
        }
        #if os(macOS)
        .padding(.leading, model.sidebarCollapsed ? Metrics.sidebarToggleX : 18)
        #else
        .padding(.leading, model.sidebarCollapsed ? 12 : 18)
        #endif
        .padding(.trailing, 12)
        #if os(macOS)
        .frame(height: Metrics.topBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
        .frostedBar()
        .padding(.bottom, Metrics.listHeaderGap)
        #else
        .frame(height: Metrics.desktopHeaderHeight)
        .frostedBar()
        #endif
    }
}

private extension View {
    /// Full-bleed list row: no insets, separators or system background (rows draw their own).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
