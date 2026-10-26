import OpenfeedCore
import SwiftUI
#if os(macOS)
import Sparkle
#endif

@main
struct OpenfeedApp: App {
    /// The single app model (owns AppDatabase via OpenfeedServices). Injected with `.environment(model)`.
    @State private var model = AppModel.live()
    #if os(macOS)
    /// Sparkle: checks the appcast on its own schedule and backs "Check for Updates…".
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    #if os(macOS)
    init() {
        // Overlay scrollers for this app even with a mouse attached (System Settings' "Automatically"
        // then means always-visible scroll bars). Otherwise SwiftUI reserves a 15pt scroll-bar gutter on
        // the right of every scroll view, so rows stop short of the right edge. overlayScrollers() then
        // shows each scroller only while the pointer is over its pane.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { OpenfeedCommands(model: model, updater: updater.updater) }
        #endif
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [services = model.services] in
            await BackgroundRefresh.run(services)
        }
        #endif
    }
}

#if os(macOS)
/// Menu bar commands. Single-key shortcuts (j/k/s/o/r/g-chords, /, ?) are handled in the window by
/// Views/Feed/KeyboardShortcuts.swift; these are the ⌘ equivalents that belong in menus.
struct OpenfeedCommands: Commands {
    let model: AppModel
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
        // Settings is an overlay in the main window (SettingsOverlay), so there's no Settings scene.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings(model.settingsTab) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Source…") { model.isAddSourcePresented = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Feed") {
            Button("Refresh") { Task { await model.refresh(force: true) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
            Button("Search") { model.openSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Filter Sources") { model.openSourceFilter() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            ForEach(FeedView.allCases) { view in
                Button(view.title) { model.navigate(view: view) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button(model.hasReaderTabs ? "Close Tab" : "Close Window") { closeTabOrWindow() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
            Button(model.focusMode ? "Exit Full-Screen Reader" : "Full-Screen Reader") { model.toggleFocusMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(model.isSplit ? "Close Split View" : "Split View") { model.toggleSplit() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.selectedItem == nil && !model.isSplit)
            Button("Show Next Tab") { model.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.panes[model.focusedPane].tabs.count < 2)
            Button("Show Previous Tab") { model.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.panes[model.focusedPane].tabs.count < 2)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.isShortcutsPresented = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }

    /// ⌘W: close the Settings overlay when it's up; else close the reader's active tab when the reader
    /// window is key and has tabs, else close the key window.
    private func closeTabOrWindow() {
        if let key = NSApp.keyWindow, key === ReaderWindow.current {
            if model.isSettingsPresented {
                model.isSettingsPresented = false
                return
            }
            if model.closeActiveTab() { return }
        }
        NSApp.keyWindow?.performClose(nil)
    }
}
#endif
