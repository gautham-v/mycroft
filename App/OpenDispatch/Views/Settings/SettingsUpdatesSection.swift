#if os(macOS)
import Sparkle
import SwiftUI

extension EnvironmentValues {
    /// Sparkle's updater (OpenDispatchApp owns it), for Settings → About.
    @Entry var updater: SPUUpdater? = nil
}

/// Settings → About on the Mac: whether updates install on their own, and a manual check. Sparkle saves
/// the switch itself (SUAutomaticallyUpdate; project.yml sets the default to on), and the checkbox in
/// its update dialog is the same value, so this follows the updater instead of keeping an AppSettings key.
struct SettingsUpdatesSection: View {
    let updater: SPUUpdater
    @State private var automatic: Bool
    @State private var canCheck: Bool
    @State private var lastCheck: Date?

    init(updater: SPUUpdater) {
        self.updater = updater
        _automatic = State(initialValue: updater.automaticallyDownloadsUpdates)
        _canCheck = State(initialValue: updater.canCheckForUpdates)
        _lastCheck = State(initialValue: updater.lastUpdateCheckDate)
    }

    var body: some View {
        SettingsSection(title: "Updates") {
            SettingsRow(
                label: "Automatically download and install updates",
                hint: automatic ? "Installs when you quit OpenDispatch." : "OpenDispatch asks before installing an update."
            ) {
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { automatic },
                    set: { updater.automaticallyDownloadsUpdates = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.ofOK)
                    .controlSize(.small)
            }
            SettingsRow(label: "Check for updates", hint: lastCheckHint) {
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(SettingsPaneButtonStyle())
                    .disabled(!canCheck)
            }
        }
        .onReceive(updater.publisher(for: \.automaticallyDownloadsUpdates)) { automatic = $0 }
        // canCheckForUpdates flips back when a check ends. lastUpdateCheckDate has no change notification.
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) {
            canCheck = $0
            lastCheck = updater.lastUpdateCheckDate
        }
    }

    /// "Last checked today at 9:41 AM", or "Last checked Oct 30 at 9:41 AM".
    private var lastCheckHint: String {
        guard let lastCheck else { return "Not checked yet" }
        let time = lastCheck.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(lastCheck)
            ? "today"
            : lastCheck.formatted(.dateTime.month(.abbreviated).day())
        return "Last checked \(day) at \(time)"
    }
}
#endif
