import OpenfeedCore
import SwiftUI

/// Top-level layout.
/// - macOS and iPad (regular width): three columns, sidebar 230 / list 410 / reader (NavigationSplitView).
///   With nothing opened the reader shows the first item (prefersDefaultSelection).
/// - iPhone (compact): tab bar Feed / Sources / Saved / Settings, each a NavigationStack.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        layout
            .tint(.ofAccent)
            .preferredColorScheme(model.settings.theme.colorScheme)
            .task { await model.start() }
            #if DEBUG
            // Debug hook for driving Settings from the command line: launch with `-OFSettingsTab data`.
            .onAppear {
                if let tab = UserDefaults.standard.string(forKey: "OFSettingsTab").flatMap(SettingsTab.init(rawValue:)) {
                    model.showSettings(tab)
                }
            }
            #endif
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
            #else
            // macOS: `model.showSettings(_:)` opens the Settings window on `settingsTab`.
            .onChange(of: model.isSettingsPresented) { _, shown in
                guard shown else { return }
                model.isSettingsPresented = false
                openSettings()
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
            .background(FlushWindowChrome())
            .frame(minWidth: 900, minHeight: 560)
        #endif
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(Metrics.sidebarWidth)
                .flushToWindowTop()
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: Metrics.listWidth, max: 520)
                .flushToWindowTop()
        } detail: {
            ReaderView()
                .flushToWindowTop()
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
                // Defer the writes: UIKit calls this from inside a UISplitViewController delegate
                // callback (e.g. while dragging a sidebar row on iPad), and mutating state there
                // re-enters the split view and raises NSInvalidArgumentException.
                DispatchQueue.main.async {
                    switch v {
                    case .all:
                        if model.sidebarCollapsed { model.sidebarCollapsed = false }
                        if model.focusMode { model.focusMode = false }
                    case .doubleColumn:
                        if !model.sidebarCollapsed { model.sidebarCollapsed = true }
                        if model.focusMode { model.focusMode = false }
                    case .detailOnly:
                        if !model.focusMode { model.focusMode = true }
                    default:
                        break
                    }
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

private extension View {
    /// macOS: the title bar is hidden and the columns draw their own room for the traffic lights,
    /// so drop the safe-area inset the hidden bar would otherwise add.
    @ViewBuilder func flushToWindowTop() -> some View {
        #if os(macOS)
        ignoresSafeArea(.container, edges: .top)
        #else
        self
        #endif
    }
}
