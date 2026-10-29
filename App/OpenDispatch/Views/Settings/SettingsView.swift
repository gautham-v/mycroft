import OpenDispatchCore
import SwiftUI

/// The pane list is AppModel's SettingsTab (so `model.showSettings(_:)` can open any pane).
typealias SettingsPane = SettingsTab

/// Port of src/components/settings-dialog.tsx. Hosted by the macOS in-window overlay (SettingsOverlay),
/// the iOS Settings tab, and the iOS/iPad sheet (`model.showSettings(_:)`).
/// - Regular width (macOS overlay, iPad sheet): the web's 140pt nav column on ground + a scrolling pane on surface.
/// - Compact width (iPhone): `SettingsPhoneRoot`, a header and grouped cards; each pane is pushed, and
///   the Sources pane's job moves to the Manage sources screen (`SourcesView`). When opened as a sheet
///   with a tab (e.g. Send to → Integrations), that pane is pushed right away; opening the sheet
///   without one (the default is Sources) shows the root.
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
            pane = model.settingsTab
            if compact, model.isSettingsPresented, pushed == nil, pane != .sources { pushed = pane }
        }
        .onChange(of: model.settingsTab) { _, tab in
            pane = tab
            if compact, model.isSettingsPresented, tab != .sources { pushed = pane }
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
        if model.settingsTab != p { model.settingsTab = p }
    }

    // MARK: Regular width

    private var splitLayout: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: pane, select: select)
                .frame(width: 214)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.ofGround)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.ofHairline).frame(width: 1) }

            ScrollView {
                paneContent(pane)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            // The pane's title and the close button sit in their own band above the pane, so rows scroll
            // under it instead of colliding with a row's control on the right.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 0) {
                    Text(pane.label)
                        .font(OFFont.ui(15, .semibold))
                        .foregroundStyle(.ofInk)
                        .padding(.leading, 28)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    closeButton
                }
                .frame(minHeight: 50)
                .background(Color.ofSurface)
            }
            .background(Color.ofSurface)
            .id(pane)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .foregroundStyle(.ofBody)
    }

    /// Close button for the iOS sheet and the macOS overlay; on macOS Esc presses it.
    @ViewBuilder private var closeButton: some View {
        if model.isSettingsPresented {
            Button {
                model.isSettingsPresented = false
            } label: {
                OFIcon.close.image
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.ofMuted)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close settings")
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            .padding(.trailing, 10)
            .padding(.top, 10)
            #else
            .padding(.trailing, 4)
            .padding(.top, 2)
            #endif
        }
    }

    private var closeButtonSize: CGFloat {
        #if os(macOS)
        Metrics.desktopIconButton
        #else
        Metrics.touchTarget
        #endif
    }

    // MARK: Compact width

    @ViewBuilder private var phoneRoot: some View {
        #if os(iOS)
        SettingsPhoneRoot(pushed: $pushed, onAddSource: { isAddSourceShown = true }, onSelect: select) { p in
            paneContent(p)
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
        case .themes:
            SettingsThemesPane()
        case .reader:
            SettingsReaderPane()
        case .playback:
            SettingsPlaybackPane()
        case .notifications:
            SettingsNotificationsPane()
        case .integrations:
            SettingsIntegrationsPane()
        case .data:
            SettingsDataPane()
        case .about:
            SettingsAboutPane()
        }
    }

    /// Tapping a source title opens its feed and leaves Settings.
    private func open(source: Source) {
        model.isSettingsPresented = false
        model.navigate(sourceID: source.id)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
        .frame(width: 640, height: 480)
}
