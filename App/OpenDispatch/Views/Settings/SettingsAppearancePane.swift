import OpenDispatchCore
import SwiftUI

/// Appearance pane (AppearancePane): theme, reader font, text size, keyboard shortcuts.
/// Values live in `model.settings` (AppSettings, JSON in UserDefaults "openfeed.settings"), which
/// RootView (theme) and the reader (font, size) already read.
struct SettingsAppearancePane: View {
    let onShowShortcuts: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Appearance", hint: "Applies on this device.")
            SettingsRow(label: "Theme") {
                SettingsSegmented(label: "Theme", selection: $model.settings.theme, options: [
                    (.light, "Light"), (.system, "System"), (.dark, "Dark"),
                ])
            }
            SettingsRow(label: "Reader font", hint: "Headline and body in the article view") {
                SettingsSegmented(label: "Reader font", selection: $model.settings.readerFont, options: [
                    (.serif, "Serif"), (.sans, "Sans"),
                ])
            }
            SettingsRow(label: "Text size") {
                SettingsSegmented(label: "Text size", selection: $model.settings.textSize, options: [
                    (.s, "S"), (.m, "M"), (.l, "L"),
                ])
            }
            SettingsTextSizePreview(font: model.settings.readerFont, size: model.settings.textSize)
            // Shortcuts need a hardware keyboard and the side-by-side layout, so not on phones.
            if !compact {
                SettingsRow(label: "Keyboard shortcuts", hint: "Or press ? anywhere") {
                    Button("Show", action: onShowShortcuts)
                        .buttonStyle(SettingsPaneButtonStyle())
                        .accessibilityLabel("Show keyboard shortcuts")
                }
            }
        }
    }
}

/// A one-line sample of the reader headline and body at the chosen font and size.
private struct SettingsTextSizePreview: View {
    let font: ReaderFontSetting
    let size: TextSizeSetting

    var body: some View {
        let headline = OFFont.headlineSize(size, wide: false) * 0.62
        let bodySize = OFFont.bodySize(size)
        VStack(alignment: .leading, spacing: 4) {
            Text("The quick brown fox")
                .font(font == .serif ? OFFont.serif(headline, .semibold) : OFFont.ui(headline, .semibold))
                .foregroundStyle(.ofInk)
            Text("Jumps over the lazy dog, as it has done in type specimens for well over a century.")
                .font(font == .serif ? OFFont.serif(bodySize) : OFFont.ui(bodySize))
                .foregroundStyle(.ofBody)
                .lineSpacing(bodySize * 0.4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
        .padding(.bottom, 10)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.12), value: size)
    }
}

/// Playback pane (PlaybackPane): autoplay and theater layout for YouTube sources.
struct SettingsPlaybackPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Playback", hint: "For YouTube sources.")
            SettingsRow(label: "Autoplay on select", hint: "Start playing when you open a video") {
                toggle("Autoplay on select", isOn: $model.settings.autoplay)
            }
            SettingsRow(label: "Theater layout", hint: "Full-width player above the title") {
                toggle("Theater layout", isOn: $model.settings.theater)
            }
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.ofOK)
            #if os(macOS)
            .controlSize(.small)
            #endif
    }
}
