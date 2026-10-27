import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The list column: the Highlights view when it is showing, else the item list. The Highlights view is
/// a navigation state of AppModel (`showsHighlights`), so it needs no item query of its own.
struct FeedColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsHighlights { HighlightsListView() } else { ItemListView() }
    }
}

/// The Highlights view: the articles that have highlights, newest highlight activity first, built from
/// the highlights table alone so it works for articles this device no longer has (or never had). Each row
/// has the source badge, the title, how many highlights it has and the latest one's text. Opening one shows
/// the article in the reader; when the item is gone it is added back from the
/// highlights' own data if its source is here, else the original URL opens in the browser
/// (HighlightStore.open).
struct HighlightsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(HighlightStore.self) private var store
    @FocusState private var searchFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    }

    private var desktopColumn: some View {
        list
            .topContentInset(Self.headerHeight)
            .overlay(alignment: .top) { HighlightsListHeader() }
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
    /// iPhone: the Saved tab's list under floating glass bubbles, like ItemListView's: the Saved / Highlights
    /// title menu and search (which filters the articles here). Opening a row pushes the reader.
    private var phoneColumn: some View {
        @Bindable var model = model
        return list
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SavedTitleMenu() }
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            }
            .searchable(text: $model.searchDraft, isPresented: Binding(
                get: { model.isSearchOpen && model.phoneTab == .saved },
                set: { open in
                    if open { model.openSearch() } else if model.isSearchOpen { model.closeSearch() }
                }), prompt: Text("Search Highlights"))
            .searchToolbarBehavior(.minimize)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationDestination(isPresented: Binding(
                get: { model.selectedItemID != nil && model.showsHighlights && model.phoneTab == .saved },
                set: { presented in if !presented, model.selectedItemID != nil { model.select(nil) } })
            ) {
                ReaderView()
            }
    }
    #endif

    /// The articles shown: on the iPhone, those matching the search (every term in the title, source or a
    /// highlight's text); the desktop layouts have no search here.
    private var groups: [HighlightGroup] {
        let terms = model.searchQuery.lowercased().split(whereSeparator: \.isWhitespace)
        guard isPhone, !terms.isEmpty else { return store.groups }
        return store.groups.filter { group in
            let haystack = ([group.title, group.sourceTitle] + group.highlights.map(\.text)).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var list: some View {
        let groups = groups
        return List {
            if groups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 64)
                    .plainRow()
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                HighlightGroupRow(group: group, previousID: index > 0 ? groups[index - 1].id : nil, isPhone: isPhone) { inNewTab in
                    Task { await store.open(group, inNewTab: inNewTab) }
                }
                .plainRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .overlayScrollers()
        .background(Color.ofSurface)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            if !store.groups.isEmpty {
                Text("No results for \u{201C}\(model.searchQuery)\u{201D}")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text("Searched titles, sources and highlights")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            } else {
                Text("No highlights yet")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                Text(isPhone ? "Select text in an article, then choose Highlight." : "Select text in an article, then Control-click to highlight it.")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// An article in the Highlights view.
private struct HighlightGroupRow: View {
    let group: HighlightGroup
    let previousID: String?
    let isPhone: Bool
    let open: (_ inNewTab: Bool) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    private var isSelected: Bool {
        guard let item = model.selectedItem else { return false }
        return item.source.feedUrl == group.sourceFeedUrl && item.item.guid == group.itemGuid
    }

    var body: some View {
        Button {
            #if os(macOS)
            open(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command))
            #else
            open(false)
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SourceBadge(host: URLHost.host(of: group.itemUrl), title: group.sourceTitle, size: Metrics.rowBadge)
                    Text(verbatim: meta)
                        .font(OFFont.itemMeta)
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(group.title)
                    .font(OFFont.itemTitle)
                    .tracking(-0.07)
                    .lineSpacing(2)
                    .foregroundStyle(.ofInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: group.latest.text)
                    .font(OFFont.itemSnippet)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.rowPaddingH)
            .padding(.vertical, Metrics.rowPaddingV)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(isSelected ? Color.ofSelection : hovered ? Color.ofHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if previousID != nil && !isSelected && !hovered {
                Rectangle()
                    .fill(Color.ofHairline)
                    .frame(height: 1)
                    .padding(.horizontal, Metrics.rowPaddingH)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
        #if os(macOS)
        .contextMenu {
            Button("Open in New Tab") { open(true) }
            if let url = URL(string: group.itemUrl) {
                Button("Open Original") { openURL(url) }
            }
        }
        #endif
        .accessibilityLabel("\(group.title), \(group.sourceTitle), \(group.count) \(group.count == 1 ? "highlight" : "highlights")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Source · 3d · 2 highlights"
    private var meta: String {
        "\(group.sourceTitle) \u{00B7} \(RelativeTime.format(group.activityAt)) \u{00B7} \(group.count) \(group.count == 1 ? "highlight" : "highlights")"
    }
}

/// The desktop list header for the Highlights view: the title and a count, with the sidebar toggle when
/// the sidebar is hidden. Like DesktopListHeader, without search and refresh (they act on item lists).
private struct HighlightsListHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(HighlightStore.self) private var store

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ListTitleMenu()
                    .layoutPriority(1)
                Text(verbatim: subline)
                    .font(OFFont.listHeaderSubline)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var subline: String {
        let n = store.count, a = store.groups.count
        guard n > 0 else { return "" }
        return "\(n) \(n == 1 ? "highlight" : "highlights") in \(a) \(a == 1 ? "article" : "articles")"
    }
}

#if os(iOS)
/// iPhone's Saved tab: the saved items or the articles with highlights, switched with the floating "Saved"
/// title menu both lists carry (SavedTitleMenu), so the rows scroll behind it and the search bubble.
struct SavedTabView: View {
    var body: some View {
        FeedColumn()
    }
}
#endif

private extension View {
    /// Full-bleed list row: no insets, separators or system background (rows draw their own).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
