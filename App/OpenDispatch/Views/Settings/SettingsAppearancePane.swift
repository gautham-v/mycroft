import OpenDispatchCore
import SwiftUI

/// Appearance pane (AppearancePane): theme, reader font, text size, line spacing, reader width (not on
/// phones, where the screen is narrower than any width), keyboard shortcuts.
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
            SettingsRow(label: "Reader font", hint: compact ? nil : "Headline and body in the article view",
                        stacked: compact) {
                SettingsSegmented(label: "Reader font", selection: $model.settings.readerFont,
                                  options: ReaderFontSetting.allCases.map { ($0, $0.label) })
            }
            SettingsRow(label: "Text size", hint: "\(OFFont.bodySize(model.settings.textSize).formatted()) pt") {
                SettingsTextSizeStepper(size: $model.settings.textSize)
            }
            SettingsRow(label: "Line spacing") {
                SettingsSegmented(label: "Line spacing", selection: $model.settings.lineSpacing,
                                  options: LineSpacingSetting.allCases.map { ($0, $0.label) })
            }
            SettingsTextSizePreview(font: model.settings.readerFont, size: model.settings.textSize,
                                    leading: model.settings.lineSpacing)
            if !compact {
                SettingsRow(label: "Reader width", hint: "Width of the article column") {
                    SettingsSegmented(label: "Reader width", selection: $model.settings.readerWidth, options: [
                        (.narrow, "Narrow"), (.medium, "Medium"), (.wide, "Wide"),
                    ])
                    .disabled(model.settings.fillWindow)
                }
                SettingsRow(label: "Fill window", hint: "Use the whole reader pane") {
                    Toggle("Fill window", isOn: $model.settings.fillWindow)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.ofOK)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
            }
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

/// Text size as steps: a smaller and a larger "A" around one dot per size, the current one and below filled.
private struct SettingsTextSizeStepper: View {
    @Binding var size: TextSizeSetting
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        HStack(spacing: 2) {
            stepButton("Smaller text", glyph: 11, to: size.smaller)
            HStack(spacing: 5) {
                ForEach(TextSizeSetting.allCases) { step in
                    Circle()
                        .fill(step.rawValue == size.rawValue || isBelow(step) ? Color.ofInk : Color.ofBorder)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
            stepButton("Larger text", glyph: 16, to: size.larger)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ofCode))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
        .accessibilityValue(size.label)
    }

    private func isBelow(_ step: TextSizeSetting) -> Bool {
        let all = TextSizeSetting.allCases
        return (all.firstIndex(of: step) ?? 0) < (all.firstIndex(of: size) ?? 0)
    }

    private func stepButton(_ label: String, glyph: CGFloat, to next: TextSizeSetting?) -> some View {
        Button {
            if let next { size = next }
        } label: {
            Text("A")
                .font(OFFont.ui(glyph, .medium))
                .foregroundStyle(next == nil ? Color.ofFaint : Color.ofInk)
                .frame(width: compact ? 44 : 32, height: compact ? 40 : 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(next == nil)
        .accessibilityLabel(label)
    }
}

/// A one-line sample of the reader headline and body at the chosen font, size and line spacing.
private struct SettingsTextSizePreview: View {
    let font: ReaderFontSetting
    let size: TextSizeSetting
    let leading: LineSpacingSetting

    var body: some View {
        let headline = OFFont.headlineSize(size, wide: false) * 0.62
        let bodySize = OFFont.bodySize(size)
        VStack(alignment: .leading, spacing: 4) {
            Text("The quick brown fox")
                .font(OFFont.reader(font, headline, .semibold))
                .foregroundStyle(.ofInk)
            Text("Jumps over the lazy dog, as it has done in type specimens for well over a century.")
                .font(OFFont.reader(font, bodySize))
                .foregroundStyle(.ofBody)
                .lineSpacing(bodySize * (leading.lineHeight - 1.2))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
        .padding(.bottom, 10)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.12), value: size)
        .animation(.easeOut(duration: 0.12), value: leading)
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
