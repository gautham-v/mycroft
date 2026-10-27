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
/// The iPhone list's floating glass bubbles (navigation bar items the rows scroll behind): the drawer's
/// hamburger at the leading edge (`showsMenu`; a source's feed pushed from Manage sources has the system
/// back button instead), the list's title in the middle and a search button at the trailing edge. While
/// searching, a search field takes the middle and a Cancel button the trailing edge.
struct PhoneListToolbar: ToolbarContent {
    var showsMenu: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.phoneDrawer) private var drawer

    var body: some ToolbarContent {
        if model.isSearchOpen {
            ToolbarItem(placement: .topBarLeading) { PhoneSearchField() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel search", systemImage: "xmark") { model.closeSearch() }
                    .labelStyle(.iconOnly)
                    .tint(.ofInk)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                if showsMenu {
                    Button(action: drawer.open) {
                        Image("ph.menu")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    .tint(.ofInk)
                    .accessibilityLabel("Menu")
                }
            }
            .sharedBackgroundVisibility(showsMenu ? .automatic : .hidden)
            ToolbarItem(placement: .principal) {
                Text(model.listTitle)
                    .font(OFFont.ui(17, .semibold))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { model.openSearch() }
                    .labelStyle(.iconOnly)
                    .tint(.ofInk)
            }
        }
    }
}

extension View {
    /// iPhone lists: nothing behind the toolbar's glass bubbles (no bar band, no scroll-edge blur or
    /// hairline), only a short fade of the ground under the status bar so the clock stays legible over
    /// rows scrolling up.
    func phoneFloatingBubbles() -> some View {
        scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: .ofSurface, location: 0), .init(color: .ofSurface, location: 0.6),
                                       .init(color: .ofSurface.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.statusBarHeight + 8)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
    }

    private static var statusBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.statusBarManager?.statusBarFrame.height ?? 54
    }
}

/// The search field that replaces the title while searching on the iPhone: a glass capsule bound to
/// `AppModel.searchDraft`, focused when it appears; Search commits right away.
private struct PhoneSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.ofMuted)
            TextField("", text: $model.searchDraft, prompt: Text(model.searchPlaceholder).foregroundStyle(.ofFaint))
                .font(OFFont.ui(17))
                .foregroundStyle(.ofInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { model.flushSearch() }
        }
        .padding(.horizontal, 14)
        // Navigation bar items size to their content: fill the bar up to the Cancel button.
        .frame(width: max(200, UIScreen.main.bounds.width - 128))
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .accessibilityLabel("Search")
    }
}

/// The big "Saved  Highlights" tabs at the top of the Saved and Highlights lists, 30pt: the inactive one
/// faint, the active one ink with a marker swipe behind its lower half.
struct SavedTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            tab("Saved", isOn: !model.showsHighlights) { model.navigate(view: .saved) }
            tab("Highlights", isOn: model.showsHighlights) { model.showHighlights() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func tab(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if !isOn { action() }
        } label: {
            Text(title)
                .font(OFFont.ui(30, .semibold))
                .tracking(-0.6)
                .foregroundStyle(isOn ? Color.ofInk : Color.ofFaint)
                .background(alignment: .bottom) {
                    if isOn {
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 6, bottomTrailingRadius: 4, topTrailingRadius: 7, style: .continuous)
                            .fill(Color.ofMarker)
                            .frame(height: 12)
                            .padding(.horizontal, -6)
                            .rotationEffect(.degrees(-1.2))
                            .offset(y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif
