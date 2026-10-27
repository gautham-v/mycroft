import AVFoundation
import SwiftUI

/// Settings → Playback → Read aloud: the voice and the default speed of the reader's Listen button.
/// The voice is stored by identifier in `AppSettings.speechVoice`; nil is the best voice installed
/// (Premium, then Enhanced, then default). Settings sync, so an identifier another device has but this
/// one lacks reads as "Best available" here and is left as it is.
struct SettingsReadAloudSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSpeech.self) private var speech
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        let voices = ReaderSpeechVoices.available()
        let showRegion = Set(voices.map(\.language)).count > 1
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(text: "Read aloud")
                .padding(.top, 22)
            SettingsRow(label: "Voice", hint: ReaderSpeechVoices.downloadHint, stacked: compact) {
                HStack(spacing: 8) {
                    Picker("Voice", selection: voiceSelection(voices)) {
                        Text(bestLabel(voices, showRegion: showRegion)).tag(String?.none)
                        ForEach(voices, id: \.identifier) { voice in
                            Text(ReaderSpeechVoices.label(voice, showRegion: showRegion)).tag(String?.some(voice.identifier))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.ofInk)
                    // On a phone the picker takes the row's width and truncates a long voice name instead of
                    // pushing the row past the screen.
                    .fixedSize(horizontal: !compact, vertical: false)
                    .lineLimit(1)
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                    Button("Preview") { speech.preview(voice: model.settings.speechVoice, speed: model.settings.speechRate) }
                        .buttonStyle(SettingsPaneButtonStyle())
                        .accessibilityLabel("Preview the voice")
                }
            }
            SettingsRow(label: "Speed", hint: "Where each article starts; change it from the player") {
                Picker("Speed", selection: $model.settings.speechRate) {
                    ForEach(ReaderPodcastPlayback.rates, id: \.self) { rate in
                        Text(ReaderPodcastPlayback.rateLabel(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.ofInk)
                .fixedSize()
            }
        }
    }

    /// The saved voice if this device has it, else nil ("Best available") without touching the saved id.
    private func voiceSelection(_ voices: [AVSpeechSynthesisVoice]) -> Binding<String?> {
        Binding(
            get: { voices.contains { $0.identifier == model.settings.speechVoice } ? model.settings.speechVoice : nil },
            set: { model.settings.speechVoice = $0 }
        )
    }

    private func bestLabel(_ voices: [AVSpeechSynthesisVoice], showRegion: Bool) -> String {
        guard let best = voices.first else { return "Best available" }
        return "Best available: \(ReaderSpeechVoices.label(best, showRegion: showRegion))"
    }
}
