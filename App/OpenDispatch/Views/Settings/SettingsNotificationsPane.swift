import OpenDispatchCore
import SwiftUI
import UserNotifications

/// Notifications pane: whether the system lets the app notify (with a way to fix it), then every source
/// with a switch for Notify on New Posts, the same setting as in a source's menu. Per device.
struct SettingsNotificationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus?
    @State private var errorMessage: String?

    private var sources: [Source] {
        model.sources.filter { !$0.isOpenedLinks }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let list = sources
        let on = list.filter(\.notifies)
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(
                title: "Notifications",
                hint: "Get a notification when a source publishes a new post. They arrive at each refresh while the app is running, and only on this device.")
            SettingsCard {
                SettingsRow(label: "Allow notifications", hint: statusHint) {
                    switch status {
                    case .denied:
                        Button("Open Settings") { openSystemSettings() }
                            .buttonStyle(SettingsPaneButtonStyle())
                    case .notDetermined:
                        Button("Allow") { Task { await allow() } }
                            .buttonStyle(SettingsPaneButtonStyle())
                    default:
                        EmptyView()
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                SettingsSectionLabel(text: "Notify on new posts")
                Spacer(minLength: 8)
                if !on.isEmpty {
                    Button("Turn all off") { turnOff(on) }
                        .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                }
            }
            .padding(.top, compact ? 0 : 22)
            .padding(.trailing, compact ? 4 : 0)
            if let errorMessage {
                Text(errorMessage)
                    .font(OFFont.ui(compact ? 13.5 : 12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, compact ? 20 : 0)
                    .padding(.bottom, 8)
            }
            SettingsCard {
                ForEach(list) { source in
                    SettingsRow(label: source.title, hint: source.host.isEmpty ? nil : source.host) {
                        Toggle("Notify on new posts from \(source.title)", isOn: binding(source))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.ofOK)
                            #if os(macOS)
                            .controlSize(.small)
                            #endif
                    }
                }
            }
        }
        .task(id: scenePhase) { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    private var statusHint: String {
        switch status {
        case .denied:
            #if os(macOS)
            "Off for OpenDispatch in System Settings › Notifications."
            #else
            "Off for OpenDispatch in Settings › Notifications."
            #endif
        case .notDetermined: "You'll be asked the first time you turn on a source."
        case nil: " "
        default: "On for this device."
        }
    }

    private func binding(_ source: Source) -> Binding<Bool> {
        Binding(
            get: { source.notifies },
            set: { on in
                Task {
                    do {
                        errorMessage = nil
                        try await model.setSourceNotify(id: source.id, on: on)
                    } catch {
                        errorMessage = HTTP.message(error)
                    }
                    status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                }
            })
    }

    private func turnOff(_ sources: [Source]) {
        Task {
            for source in sources { try? await model.setSourceNotify(id: source.id, on: false) }
        }
    }

    private func allow() async {
        _ = await PostNotifications.requestAuthorization()
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openSystemSettings() {
        #if os(macOS)
        let link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        #else
        let link = UIApplication.openNotificationSettingsURLString
        #endif
        if let url = URL(string: link) { openURL(url) }
    }
}
