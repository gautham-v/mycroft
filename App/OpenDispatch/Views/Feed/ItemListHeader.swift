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
                Text(model.listTitle)
                    .font(OFFont.listHeaderTitle)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
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

/// iPhone filter toolbar button (replaces the old view chips): a Menu with the content type (All,
/// Articles, Posts, Video, Podcasts; Feed tab only) and the hn100 / labs / blogs filter, both single
/// selection, then Copy Last 24 Hours / 7 Days of what the list shows. The symbol fills while anything
/// but All / no filter is active.
struct FeedFilterMenu: View {
    @Environment(AppModel.self) private var model
    /// Show the content-type section (the Feed tab's home list, not Saved or a source/folder feed).
    var showsContentTypes: Bool

    static let contentTypes: [FeedView] = [.all, .articles, .posts, .video, .podcasts]
    static let filters: [(FeedFilter, String)] = [(.hn100, "HN \u{2265} 100"), (.labs, "Labs"), (.blogs, "Blogs")]

    private var isActive: Bool {
        model.filter != nil || (showsContentTypes && model.selectedView != .all)
    }

    var body: some View {
        Menu {
            if showsContentTypes {
                Section("Show") {
                    ForEach(Self.contentTypes) { view in
                        Toggle(view.title, isOn: contentTypeBinding(view))
                    }
                }
            }
            Section("Filter") {
                ForEach(Self.filters, id: \.0) { filter, label in
                    Toggle(label, isOn: filterBinding(filter))
                }
            }
            Section("Copy as Markdown") {
                CopyDigestButtons(scope: model.currentDigestScope, filter: model.filter, icons: true)
            }
        } label: {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        // Monochrome like the system search item; accent only while a selection is active.
        .tint(isActive ? Color.ofAccent : Color.primary)
        .accessibilityLabel("Filter")
        .accessibilityValue(isActive ? "On" : "Off")
    }

    /// Single selection: checking a type switches to it; unchecking the current one keeps it.
    private func contentTypeBinding(_ view: FeedView) -> Binding<Bool> {
        Binding(
            get: { model.selectedView == view },
            set: { on in if on, view != model.selectedView { model.navigate(view: view) } })
    }

    private func filterBinding(_ filter: FeedFilter) -> Binding<Bool> {
        Binding(
            get: { model.filter == filter },
            set: { on in model.setFilter(on ? filter : (model.filter == filter ? nil : model.filter)) })
    }
}
