#if os(macOS)
import AppKit
import SwiftUI

/// macOS Settings: a centered panel over the dimmed main window (like the Claude desktop app's settings
/// dialog), not a separate window. RootView shows it while `model.isSettingsPresented`; Esc, the
/// panel's close button (SettingsView) or a click on the backdrop dismisses it. The feed's single-key
/// shortcuts stand down while it's up (KeyboardShortcuts.swift).
struct SettingsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Self.backdrop
                .contentShape(Rectangle())
                .onTapGesture { model.isSettingsPresented = false }
                .accessibilityLabel("Close settings")
                .accessibilityAddTraits(.isButton)

            SettingsView()
                .frame(maxWidth: Self.maxSize.width, maxHeight: Self.maxSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(Color.ofHairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
                .padding(40)
                .accessibilityAddTraits(.isModal)
        }
        .ignoresSafeArea()
        // Take focus from whatever had it under the backdrop (e.g. the sidebar filter), so typing
        // doesn't land in a field the panel covers.
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private static let maxSize = CGSize(width: 720, height: 520)
    private static let radius: CGFloat = 12
    /// Dark mode dims harder: the window is already near-black there.
    private static let backdrop = Color(light: 0x000000, lightAlpha: 0.3, dark: 0x000000, darkAlpha: 0.5)
}
#endif
