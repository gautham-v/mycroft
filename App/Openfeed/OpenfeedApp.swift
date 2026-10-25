import OpenfeedCore
import SwiftUI

@main
struct OpenfeedApp: App {
    /// The single app model (owns AppDatabase via OpenfeedServices). Injected with `.environment(model)`.
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { OpenfeedCommands(model: model) }
        #endif
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [services = model.services] in
            await BackgroundRefresh.run(services)
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 460)
        }
        #endif
    }
}

#if os(macOS)
/// Menu bar commands. Single-key shortcuts (j/k/s/o/r/g-chords, /, ?) are handled in the window by
/// Views/Feed/KeyboardShortcuts.swift; these are the ⌘ equivalents that belong in menus.
struct OpenfeedCommands: Commands {
    let model: AppModel

    var body: some Commands {
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
            Divider()
            ForEach(FeedView.allCases) { view in
                Button(view.title) { model.navigate(view: view) }
            }
        }
        CommandGroup(after: .sidebar) {
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
            Button(model.focusMode ? "Exit Full-Screen Reader" : "Full-Screen Reader") { model.toggleFocusMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.isShortcutsPresented = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
#endif
