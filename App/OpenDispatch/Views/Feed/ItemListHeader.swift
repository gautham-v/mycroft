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
/// The list's title as its first row on the iPhone (All, Articles, a folder, Saved, Highlights, a
/// source): 32pt semibold, so it scrolls away with the rows.
struct PhoneTitleRow: View {
    @Environment(AppModel.self) private var model

    /// The row's id, to scroll the list back to the very top.
    static let id = "phone-title"

    var body: some View {
        Text(model.listTitle)
            .font(OFFont.ui(32, .semibold))
            .tracking(-0.7)
            .foregroundStyle(.ofInk)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(Self.id)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The iPhone list's floating Liquid Glass bubbles along the bottom, over the rows: the drawer's hamburger
/// at the leading edge and a pill of page dots in the middle (`isHome`; a source's feed pushed from Manage
/// sources has the system back button at the top instead, and the dots only show while the list is one of
/// the content views), and search at the trailing edge. Searching replaces them all with a glass search
/// field and a close button, above the keyboard.
private struct PhoneBottomBar: View {
    let isHome: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.phoneDrawer) private var drawer

    var body: some View {
        Group {
            if model.isSearchOpen {
                PhoneSearchBar()
            } else {
                GlassEffectContainer(spacing: 16) {
                    ZStack {
                        HStack {
                            if isHome { menuButton }
                            Spacer(minLength: 0)
                            searchButton
                        }
                        if isHome, model.phonePageIndex != nil { PhonePageDots() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        // 22pt from the screen's bottom edge (inside the home indicator's area); above the keyboard while searching.
        .padding(.bottom, model.isSearchOpen ? 8 : -12)
    }

    private var menuButton: some View {
        Button(action: drawer.open) {
            Image("ph.menu")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.ofInk)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Menu")
    }

    private var searchButton: some View {
        Button { model.openSearch() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.ofInk)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Search")
    }
}

/// The pill of page dots, one per content view with the current one stretched to a capsule. Tapping it opens a
/// menu of the views in page order, the current one checked.
private struct PhonePageDots: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pages = model.phonePages
        let current = model.phonePageIndex
        Menu {
            ForEach(pages, id: \.self) { view in
                Toggle(view.title, isOn: Binding(
                    get: { pages.firstIndex(of: view) == current },
                    set: { _ in model.navigate(view: view) }))
            }
        } label: {
            HStack(spacing: 5) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(index == current ? Color.ofInk : Color.ofFaint)
                        .frame(width: index == current ? 18 : 6, height: 6)
                }
            }
            .animation(.smooth(duration: 0.2), value: current)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Opening upward from the bottom, iOS would otherwise list the views bottom to top.
        .menuOrder(.fixed)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("\(model.listTitle), switch view")
    }
}

/// The glass search field that replaces the bubbles while searching on the iPhone, bound to
/// `AppModel.searchDraft` and focused when it appears; Search commits right away. The close button empties
/// it and closes the search.
private struct PhoneSearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
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
                .padding(.horizontal, 16)
                .frame(height: 46)
                .glassEffect(.regular, in: .capsule)
                Button { model.closeSearch() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.ofInk)
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close search")
            }
        }
        .onAppear { focused = true }
        // Opening an article puts the keyboard away; the field stays as it was.
        .onChange(of: model.selectedItemID) { _, id in if id != nil { focused = false } }
    }
}

extension View {
    /// The iPhone list's chrome around a `List`: room under the last row for the bottom bubbles, the bubbles
    /// themselves over the rows (`isHome`: with the hamburger and page dots), no navigation bar band,
    /// scroll-edge blur or hairline at the top, and a short fade of the ground under the status bar so the
    /// clock stays legible over rows scrolling up. `showsBubbles` is false for a list that is in the stack
    /// but not the one on screen.
    func phoneListChrome(isHome: Bool, showsBubbles: Bool) -> some View {
        contentMargins(.bottom, 56, for: .scrollContent)
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: .ofSurface, location: 0), .init(color: .ofSurface, location: 0.6),
                                       .init(color: .ofSurface.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.statusBarHeight + 8)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if showsBubbles {
                    PhoneBottomBar(isHome: isHome)
                }
            }
    }

    private static var statusBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.statusBarManager?.statusBarFrame.height ?? 54
    }
}
#endif
