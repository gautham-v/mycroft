#if os(iOS)
import OpenDispatchCore
import SwiftUI

/// The iPhone Settings screen, shown in a sheet over the Feed (Done at top trailing): the app icon in
/// a glass circle with the name and version, then grouped cards. The first holds the source actions
/// (Add source, Import OPML, Manage sources), the rest lead to the panes, which push on the sheet's
/// NavigationStack, as does Manage sources (`SourcesView`).
struct SettingsPhoneRoot<PaneContent: View>: View {
    @Binding var pushed: SettingsPane?
    let onAddSource: () -> Void
    let onSelect: (SettingsPane) -> Void
    @ViewBuilder let pane: (SettingsPane) -> PaneContent

    @Environment(AppModel.self) private var model
    @State private var isImportingOPML = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                VStack(spacing: 8) {
                    GroupedLabel(text: "Sources")
                    GroupedCard {
                        Button(action: onAddSource) {
                            GroupedRow(title: "Add source", chevron: false, weight: .semibold) {
                                GroupedIcon(systemName: OFIcon.plus.rawValue)
                            }
                        }
                        Button { isImportingOPML = true } label: {
                            GroupedRow(title: "Import OPML", chevron: false) {
                                GroupedIcon(systemName: "square.and.arrow.down")
                            }
                        }
                        paneRow(.sources, title: "Manage sources", detail: "\(model.sources.count)") {
                            GroupedIcon(systemName: OFIcon.list.rawValue)
                        }
                    }
                }
                GroupedCard {
                    paneRow(.appearance, detail: model.settings.theme.label)
                    paneRow(.playback)
                    paneRow(.notifications, detail: notificationsDetail)
                }
                GroupedCard {
                    paneRow(.integrations, detail: integrationsDetail)
                    paneRow(.data)
                }
                GroupedCard {
                    paneRow(.about)
                }
            }
            .buttonStyle(GroupedRowButtonStyle())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.ofSurface)
        .opmlImporter(isPresented: $isImportingOPML)
        .navigationTitle("Settings")
        // No title text in the bar: the hero says what this is.
        .toolbar(removing: .title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSettingsPresented {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.isSettingsPresented = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .navigationDestination(item: $pushed) { p in
            Group {
                if p == .sources {
                    SourcesView()
                } else {
                    ScrollView {
                        pane(p)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(p.label)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .background(Color.ofSurface)
            .environment(\.settingsCompact, true)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .frame(width: 104, height: 104)
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            Text("OpenDispatch")
                .font(OFFont.ui(26, .semibold))
                .tracking(-0.5)
                .foregroundStyle(.ofInk)
            Text(version)
                .font(OFFont.ui(14))
                .foregroundStyle(.ofMuted)
                .textSelection(.enabled)
                .padding(.top, -6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// How many sources notify on new posts, when any do.
    private var notificationsDetail: String? {
        let n = (model.sources + model.topics).filter(\.notifies).count
        return n == 0 ? nil : "\(n)"
    }

    /// "Readwise" (or "Webhook") once a send target is set up.
    private var integrationsDetail: String? {
        let state = model.integrations
        if state.readwiseConfigured { return "Readwise" }
        return state.webhookURL == nil ? nil : "Webhook"
    }

    private func paneRow(_ p: SettingsPane, title: String? = nil, detail: String? = nil) -> some View {
        paneRow(p, title: title, detail: detail) { EmptyView() }
    }

    private func paneRow<Leading: View>(_ p: SettingsPane, title: String? = nil, detail: String? = nil,
                                        @ViewBuilder leading: @escaping () -> Leading) -> some View {
        Button {
            onSelect(p)
            pushed = p
        } label: {
            GroupedRow(title: title ?? p.label, detail: detail, leading: leading)
        }
    }
}
#endif
