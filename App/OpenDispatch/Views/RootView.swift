import OpenDispatchCore
import SwiftUI

/// Top-level layout.
/// - macOS and iPad (regular width): three columns, sidebar 230 / list 410 / reader (NavigationSplitView).
///   With nothing opened the reader shows the first item (prefersDefaultSelection).
/// - iPhone (compact): no tab bar; one NavigationStack with a side drawer for views, folders, sources and
///   Settings (PhoneRoot). Settings and Add source are sheets.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    /// Where the reader is drawn (see `MacReaderOverlay`). An observed object, not @State here: the
    /// frame changes on every step of a window resize, and only the overlay should re-render for it,
    /// not this view and with it the sidebar and item list.
    @State private var detailFrame = DetailColumnFrame()
    #endif

    var body: some View {
        @Bindable var model = model
        layout
            .copyToastOverlay()
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
            .openDispatchAutoRefresh()
            .onOpenURL { url in model.handleOpenURL(url) }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    Task { await model.refresh(force: false) }
                    Task { await model.syncNow() }
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
            // An empty, invisible item keeps the window toolbar (and the 38pt title bar it brings) in
            // place when the sidebar hides. Without one SwiftUI drops the toolbar, and the bare title
            // bar then takes clicks meant for the list header's top row.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay { MacReaderOverlay(detailFrame: detailFrame) }
            // Settings: a panel over the dimmed window (`model.showSettings(_:)`, ⌘,), not a window.
            .overlay {
                ZStack {
                    if model.isSettingsPresented { SettingsOverlay().transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.15), value: model.isSettingsPresented)
            }
            .background(FlushWindowChrome())
            .frame(minWidth: 900, minHeight: 560)
        #endif
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                // On macOS HairlineSplitView handles the drag limits (SwiftUI's aren't applied).
                .navigationSplitViewColumnWidth(min: Metrics.sidebarMinWidth, ideal: Metrics.sidebarWidth, max: Metrics.sidebarMaxWidth)
                #if os(macOS)
                // The sidebar header and list header draw their own toggle (white, like Claude's).
                .toolbar(removing: .sidebarToggle)
                #endif
                .flushToWindowTop()
        } content: {
            FeedColumn()
                .navigationSplitViewColumnWidth(min: Metrics.listMinWidth, ideal: Metrics.listWidth, max: Metrics.listMaxWidth)
                .flushToWindowTop()
        } detail: {
            Group {
                #if os(macOS)
                // The reader itself is drawn over this column (`MacReaderOverlay`); this marks where.
                Color.ofSurface
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { detailFrame.rect = $0 }
                #else
                ReaderView()
                #endif
            }
            .flushToWindowTop()
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.prefersDefaultSelection = true }
    }

    /// Sidebar visibility follows `sidebarCollapsed`; the full-screen reader shows the detail only.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                #if os(iOS)
                if model.isFocused { return .detailOnly }
                #endif
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
        PhoneRoot()
    }
    #endif
}

#if os(macOS)
/// The detail column's frame in window coordinates.
@MainActor
@Observable
final class DetailColumnFrame {
    var rect: CGRect = .zero
}

/// The one reader view, drawn over the detail column, or over the whole window in the full-screen
/// reader. macOS NavigationSplitView doesn't hide the content column for `.detailOnly`, and moving
/// the reader between the column and a full-window overlay rebuilt it, restarting a playing video;
/// resizing the same view keeps it (and its web view) alive.
private struct MacReaderOverlay: View {
    let detailFrame: DetailColumnFrame
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.frame(in: .global)
            let frame = model.isFocused ? window : detailFrame.rect
            ReaderView()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - window.minX, y: frame.minY - window.minY)
        }
        .ignoresSafeArea()
    }
}
#endif

#Preview {
    let model = AppModel.preview()
    return RootView().environment(model).environment(HighlightStore(model: model))
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
