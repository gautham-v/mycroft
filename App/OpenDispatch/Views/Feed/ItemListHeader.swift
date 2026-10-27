import OpenDispatchCore
import SwiftUI

/// Desktop and iPad list header (openfeed-app.tsx, lg and up): 44pt on the Mac's top row (54pt on iPad), title, search
/// button (or the search field in place of the title), refresh button.
/// A show-sidebar button leads when the sidebar is collapsed.
struct DesktopListHeader: View {
    @Environment(AppModel.self) private var model
    var searchFocus: FocusState<Bool>.Binding

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
                .help("Show sidebar (⌘\\)")
                .accessibilityLabel("Show sidebar")
            }
            if model.isSearchOpen {
                FeedSearchField(focus: searchFocus)
            } else {
                ListTitleMenu()
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeedSearchButton(searchFocus: searchFocus)
            }
            FeedRefreshButton()
        }
        #if os(macOS)
        // Collapsed: the toggle sits where the sidebar header had it, after the traffic lights.
        .padding(.leading, model.sidebarCollapsed ? Metrics.sidebarToggleX : 18)
        #else
        .padding(.leading, model.sidebarCollapsed ? 12 : 18)
        #endif
        .padding(.trailing, 12)
        #if os(macOS)
        // The top row shared with the reader bar, with the same hairline under it. The gap below
        // stays clear: rows show through it unblurred.
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

/// The list title as a menu: the sidebar's views (minus hidden ones, plus Highlights) and folders, the current one
/// checked (none while a single source shows), then Show / Hide Sidebar. Never lists individual sources.
struct ListTitleMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(SidebarViewItem.ordered.filter { !model.isSidebarViewHidden($0) }) { item in
                switch item {
                case .view(let view):
                    Toggle(view.title, isOn: Binding(get: { isActive(item) }, set: { _ in model.navigate(view: view) }))
                case .highlights:
                    Toggle("Highlights", isOn: Binding(get: { isActive(item) }, set: { _ in model.showHighlights() }))
                }
            }
            if !model.orderedFolders.isEmpty {
                Divider()
                ForEach(model.orderedFolders) { folder in
                    Toggle(folder.title, isOn: Binding(
                        get: { model.selectedFolderID == folder.id && model.selectedSourceID == nil },
                        set: { _ in model.navigate(folderID: folder.id) }))
                }
            }
            Divider()
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
        } label: {
            HStack(spacing: 5) {
                Text(model.listTitle)
                    .font(OFFont.listHeaderTitle)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.ofMuted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovered ? Color.ofNavHover : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
        .padding(.leading, -6)
        .accessibilityLabel("\(model.listTitle), switch view")
    }

    /// Same test as the sidebar's rows.
    private func isActive(_ item: SidebarViewItem) -> Bool {
        switch item {
        case .view(let view):
            model.selectedView == view && model.selectedSourceID == nil && model.selectedFolderID == nil && !model.showsHighlights
        case .highlights:
            model.showsHighlights
        }
    }
}

/// Refresh feeds (forced). Spins while refreshing; disabled meanwhile. (iPhone uses pull to refresh.)
struct FeedRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: { Task { await model.refresh(force: true) } }) {
            OFIcon.refresh.image
                .font(.system(size: 15, weight: .regular))
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isRefreshing)
                .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedHoverIconButtonStyle())
        .disabled(model.isRefreshing)
        .opacity(model.isRefreshing ? 0.7 : 1)
        .help("Refresh (r)")
        .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh feeds")
    }
}

/// Opens and focuses the search field. (iPhone uses `.searchable`.)
struct FeedSearchButton: View {
    @Environment(AppModel.self) private var model
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        Button(action: {
            model.openSearch()
            Task { @MainActor in
                await Task.yield()
                searchFocus.wrappedValue = true
            }
        }) {
            OFIcon.search.image
                .font(.system(size: 15))
                .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedHoverIconButtonStyle())
        .help("Search (/)")
        .accessibilityLabel("Search")
    }
}


#if os(iOS)
/// The iPhone's list title as a menu, in the navigation bar's leading slot: the title with a chevron, which
/// the system draws as a floating Liquid Glass bubble like the search item opposite. `items` are the menu's
/// entries (FeedTitleMenu, SavedTitleMenu).
struct PhoneTitleMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(OFFont.ui(17, .semibold))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.ofMuted)
            }
            .padding(.horizontal, 4)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("\(title), switch view")
    }
}

/// The Feed tab's title menu: the content-type views (All, Articles, Posts, Video, Podcasts, less the ones hidden
/// in Settings; Saved and Highlights live in the Saved tab), then the folders, the current one checked (none
/// while a source shows), then Copy Last 24 Hours / 7 Days of what the list shows.
struct FeedTitleMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PhoneTitleMenu(title: model.listTitle) {
            ForEach(Self.views.filter { !model.isSidebarViewHidden(.view($0)) }) { view in
                Toggle(view.title, isOn: Binding(
                    get: { model.selectedView == view && !model.isInSourceFeed },
                    set: { _ in model.navigate(view: view) }))
            }
            if !model.orderedFolders.isEmpty {
                Divider()
                ForEach(model.orderedFolders) { folder in
                    Toggle(folder.title, isOn: Binding(
                        get: { model.selectedFolderID == folder.id && model.selectedSourceID == nil },
                        set: { _ in model.navigate(folderID: folder.id) }))
                }
            }
            Divider()
            CopyDigestButtons(scope: model.currentDigestScope)
        }
    }

    /// The sidebar's views that belong on the Feed tab.
    private static let views: [FeedView] = SidebarViewItem.ordered.compactMap {
        if case .view(let view) = $0, view != .saved { view } else { nil }
    }
}

/// The Saved tab's title menu: Saved or Highlights.
struct SavedTitleMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PhoneTitleMenu(title: model.showsHighlights ? "Highlights" : "Saved") {
            Toggle("Saved", isOn: Binding(
                get: { !model.showsHighlights },
                set: { _ in if model.showsHighlights { model.navigate(view: .saved) } }))
            Toggle("Highlights", isOn: Binding(
                get: { model.showsHighlights },
                set: { _ in if !model.showsHighlights { model.showHighlights() } }))
        }
    }
}
#endif
