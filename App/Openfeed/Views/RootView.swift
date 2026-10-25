import OpenfeedCore
import SwiftUI

/// Top-level layout.
/// - macOS and iPad (regular width): three columns, sidebar 230 / list 410 / reader (NavigationSplitView).
///   With nothing opened the reader shows the first item (prefersDefaultSelection).
/// - iPhone (compact): tab bar Feed / Sources / Saved / Settings, each a NavigationStack.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        layout
            .tint(.ofAccent)
            .preferredColorScheme(model.settings.theme.colorScheme)
            .task { await model.start() }
            .openfeedAutoRefresh()
            .onOpenURL { url in model.handleOpenURL(url) }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await model.refresh(force: false) }
                case .background: BackgroundRefresh.schedule()
                default: break
                }
            }
            .sheet(isPresented: $model.isAddSourcePresented) {
                AddSourceView().environment(model)
            }
            .sheet(isPresented: $model.isShortcutsPresented) {
                ShortcutsView().environment(model)
            }
            #if os(iOS)
            .sheet(isPresented: $model.isSettingsPresented) {
                NavigationStack { SettingsView() }.environment(model)
            }
            #endif
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            phoneLayout
                .onAppear { model.prefersDefaultSelection = false }
        } else {
            splitLayout
        }
        #else
        splitLayout
            .toolbar(removing: .title)
            .frame(minWidth: 900, minHeight: 560)
        #endif
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(Metrics.sidebarWidth)
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: Metrics.listWidth, max: 520)
        } detail: {
            ReaderView()
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.prefersDefaultSelection = true }
    }

    /// Sidebar visibility follows `sidebarCollapsed`; the full-screen reader shows the detail only.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                if model.isFocused { return .detailOnly }
                return model.sidebarCollapsed ? .doubleColumn : .all
            },
            set: { v in
                switch v {
                case .all:
                    model.sidebarCollapsed = false
                    model.focusMode = false
                case .doubleColumn:
                    model.sidebarCollapsed = true
                    model.focusMode = false
                case .detailOnly:
                    model.focusMode = true
                default:
                    break
                }
            })
    }

    #if os(iOS)
    private var phoneLayout: some View {
        @Bindable var model = model
        return TabView(selection: $model.phoneTab) {
            Tab("Feed", systemImage: OFIcon.inbox.rawValue, value: PhoneTab.feed) {
                NavigationStack { ItemListView() }
            }
            Tab("Sources", systemImage: OFIcon.folder.rawValue, value: PhoneTab.sources) {
                NavigationStack { SourcesView() }
            }
            Tab("Saved", systemImage: OFIcon.bookmark.rawValue, value: PhoneTab.saved) {
                NavigationStack { ItemListView() }
            }
            Tab("Settings", systemImage: OFIcon.gear.rawValue, value: PhoneTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
    }
    #endif
}

#Preview {
    RootView().environment(AppModel.preview())
}
