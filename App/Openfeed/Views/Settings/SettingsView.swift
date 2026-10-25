import OpenfeedCore
import SwiftUI

/// Settings panes. The first four are the web app's tabs (SettingsTab, owned by AppModel so the reader
/// can open Integrations); Data and About are native additions.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sources, appearance, playback, integrations, data, about

    var id: String { rawValue }

    init(_ tab: SettingsTab) {
        switch tab {
        case .sources: self = .sources
        case .appearance: self = .appearance
        case .playback: self = .playback
        case .integrations: self = .integrations
        }
    }

    /// The matching AppModel tab, nil for the native-only panes.
    var tab: SettingsTab? {
        switch self {
        case .sources: .sources
        case .appearance: .appearance
        case .playback: .playback
        case .integrations: .integrations
        case .data, .about: nil
        }
    }

    var label: String {
        switch self {
        case .sources: "Sources"
        case .appearance: "Appearance"
        case .playback: "Playback"
        case .integrations: "Integrations"
        case .data: "Data"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .sources: OFIcon.folder.rawValue
        case .appearance: "textformat.size"
        case .playback: OFIcon.video.rawValue
        case .integrations: OFIcon.send.rawValue
        case .data: "internaldrive"
        case .about: "info.circle"
        }
    }
}

/// Port of src/components/settings-dialog.tsx. Hosted by the macOS Settings scene, the iOS Settings
/// tab, and the iOS/iPad sheet (`model.showSettings(_:)`).
/// - Regular width (macOS, iPad sheet): the web's 140pt nav column on ground + a scrolling pane on surface.
/// - Compact width (iPhone): a list of sections; each opens its pane. When opened as a sheet with a tab
///   (e.g. Send to → Integrations), that pane is pushed right away.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var pane: SettingsPane = .sources
    /// Phone: the pane pushed on the surrounding NavigationStack.
    @State private var pushed: SettingsPane?
    @State private var isShortcutsShown = false
    @State private var isAddSourceShown = false

    private var compact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if compact {
                phoneRoot
            } else {
                splitLayout
            }
        }
        .environment(\.settingsCompact, compact)
        .onAppear {
            pane = SettingsPane(model.settingsTab)
            if compact, model.isSettingsPresented, pushed == nil { pushed = pane }
        }
        .onChange(of: model.settingsTab) { _, tab in
            pane = SettingsPane(tab)
            if compact, model.isSettingsPresented { pushed = pane }
        }
        .task { await model.loadIntegrations() }
        .sheet(isPresented: $isShortcutsShown) {
            ShortcutsView().environment(model)
        }
        .sheet(isPresented: $isAddSourceShown) {
            AddSourceView().environment(model)
        }
    }

    private func select(_ p: SettingsPane) {
        pane = p
        if let tab = p.tab, model.settingsTab != tab { model.settingsTab = tab }
    }

    // MARK: Regular width

    private var splitLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(OFFont.ui(11, .semibold))
                    .tracking(0.11)
                    .foregroundStyle(.ofFaint)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                ForEach(SettingsPane.allCases) { p in
                    SettingsNavRow(title: p.label, selected: pane == p) { select(p) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .frame(width: 140)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.ofGround)

            ScrollView {
                paneContent(pane)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .background(Color.ofSurface)
            .id(pane)
        }
        .overlay(alignment: .topTrailing) { closeButton }
        #if os(macOS)
        .navigationTitle(pane.label)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .foregroundStyle(.ofBody)
    }

    /// iOS sheet close button (the macOS Settings window has its own).
    @ViewBuilder private var closeButton: some View {
        #if os(iOS)
        if model.isSettingsPresented {
            Button {
                model.isSettingsPresented = false
            } label: {
                OFIcon.close.image
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.ofMuted)
                    .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close settings")
            .padding(.trailing, 4)
            .padding(.top, 2)
        }
        #endif
    }

    // MARK: Compact width

    private var phoneRoot: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(SettingsPane.allCases) { p in
                    // Shortcuts and theater layout still make sense on phones; all panes are listed.
                    Button {
                        select(p)
                        pushed = p
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.symbol)
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.ofMuted)
                                .frame(width: 24)
                            Text(p.label)
                                .font(OFFont.ui(16))
                                .foregroundStyle(.ofInk)
                            Spacer()
                            OFIcon.chevron.image
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.ofFaint)
                        }
                        .frame(minHeight: Metrics.touchTarget + 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if p != SettingsPane.allCases.last { SettingsHairline().padding(.leading, 36) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.ofSurface)
        .navigationTitle("Settings")
        .navigationDestination(item: $pushed) { p in
            ScrollView {
                paneContent(p)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.ofSurface)
            .navigationTitle(p.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .environment(\.settingsCompact, true)
        }
        #if os(iOS)
        .toolbar {
            if model.isSettingsPresented {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.isSettingsPresented = false }
                }
            }
        }
        #endif
    }

    // MARK: Panes

    @ViewBuilder private func paneContent(_ p: SettingsPane) -> some View {
        switch p {
        case .sources:
            SettingsSourcesPane(onAdd: { isAddSourceShown = true }, onOpen: open(source:))
        case .appearance:
            SettingsAppearancePane(onShowShortcuts: { isShortcutsShown = true })
        case .playback:
            SettingsPlaybackPane()
        case .integrations:
            SettingsIntegrationsPane()
        case .data:
            SettingsDataPane()
        case .about:
            SettingsAboutPane()
        }
    }

    /// Tapping a source title opens its feed (and leaves Settings on iOS).
    private func open(source: Source) {
        #if os(iOS)
        if compact {
            // Feed first: selecting the tab goes home, then show the source.
            model.phoneTab = .feed
        }
        model.isSettingsPresented = false
        #endif
        model.navigate(sourceID: source.id)
    }
}

/// Left nav row (NAV_ROW): 32pt, 14pt ink, nav-selection / nav-hover backgrounds.
private struct SettingsNavRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OFFont.ui(14))
                .foregroundStyle(.ofInk)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Metrics.sidebarRowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .fill(selected ? Color.ofNavSelection : (hovering ? Color.ofNavHover : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
        .frame(width: 640, height: 480)
}
