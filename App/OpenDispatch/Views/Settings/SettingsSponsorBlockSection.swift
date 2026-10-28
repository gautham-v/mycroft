import OpenDispatchCore
import SwiftUI

/// Settings → Playback → SponsorBlock: a master switch and, per segment category, what the player does with
/// it (skip, mute, mark it on the scrubber, or ignore it). `AppSettings.sponsorBlockModes` holds only the
/// categories changed from their default. Segments come from sponsor.ajay.app (CC BY-NC-SA 4.0), which asks
/// for the credit line at the bottom.
struct SettingsSponsorBlockSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(text: "SponsorBlock")
                .padding(.top, compact ? 0 : 22)
            SettingsCard {
                SettingsRow(label: "Skip sponsored segments (SponsorBlock)", hint: "Act on segments viewers have marked in YouTube videos") {
                    Toggle("Skip sponsored segments (SponsorBlock)", isOn: $model.settings.sponsorBlock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.ofOK)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
                ForEach(SponsorBlockCategory.allCases) { category in
                    SettingsRow(label: category.title, hint: category.summary, swatch: Color(hexString: category.colorHex)) {
                        Picker(category.title, selection: mode(category)) {
                            ForEach(category.allowedModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(.ofInk)
                        .fixedSize()
                    }
                    .disabled(!model.settings.sponsorBlock)
                }
            }
            Text("Segments from [SponsorBlock (sponsor.ajay.app)](https://sponsor.ajay.app), CC BY-NC-SA 4.0.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .tint(.ofAccent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? 20 : 0)
                .padding(.top, compact ? 0 : 8)
                .padding(.bottom, compact ? 22 : 0)
        }
    }

    private func mode(_ category: SponsorBlockCategory) -> Binding<SponsorBlockMode> {
        Binding(
            get: { model.settings.sponsorBlockMode(category) },
            set: { model.settings.setSponsorBlockMode($0, for: category) }
        )
    }
}
