import AVFoundation
import SwiftUI

/// Settings → Playback → Read aloud: the voice and the default speed of the reader's Listen button.
/// The voice is stored by identifier in `AppSettings.speechVoice` (`NaturalVoice.voiceID` for the natural
/// voice); nil is the best one: the natural voice for English, else the best system voice installed
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
                .padding(.top, compact ? 0 : 22)
            SettingsCard {
                SettingsRow(label: "Voice", hint: hint, stacked: compact) {
                    HStack(spacing: 8) {
                        let picker = Picker("Voice", selection: voiceSelection(voices)) {
                            Text(bestLabel(voices, showRegion: showRegion)).tag(String?.none)
                            if Self.offersNatural {
                                Text(ReaderSpeechVoices.naturalLabel).tag(String?.some(NaturalVoice.voiceID))
                            }
                            ForEach(voices, id: \.identifier) { voice in
                                Text(ReaderSpeechVoices.label(voice, showRegion: showRegion)).tag(String?.some(voice.identifier))
                            }
                        }
                        if compact {
                            // A phone's picker is a menu whose label takes the row's width and truncates a long
                            // voice name; a Picker's own label wraps and spills out of the row.
                            Menu {
                                picker.pickerStyle(.inline)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(selectedLabel(voices, showRegion: showRegion))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .tint(.ofInk)
                            .accessibilityLabel("Voice")
                        } else {
                            picker
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(.ofInk)
                                .fixedSize(horizontal: true, vertical: false)
                                .lineLimit(1)
                        }
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
    }

    /// The natural voice speaks English only, so it is offered when that is the user's language.
    private static var offersNatural: Bool { ReaderSpeechVoices.userLanguage == "en" }

    /// The natural voice reads what Preview and English articles say.
    private var natural: Bool { ReaderSpeechVoices.prefersNatural(saved: model.settings.speechVoice, language: nil) }

    private var hint: String {
        guard natural else { return ReaderSpeechVoices.downloadHint }
        switch speech.natural.phase {
        case .downloading: return "Downloading the natural voice…"
        case .loading: return "Loading the natural voice…"
        case .failed: return "The natural voice couldn't download; the system voice reads until it does."
        case .ready: return "Runs on this device. Articles in other languages use the system voice."
        case .notLoaded: return "Downloads about 90 MB the first time it speaks, then runs on this device."
        }
    }

    /// The saved voice if this device has it, else nil ("Best available") without touching the saved id.
    private func voiceSelection(_ voices: [AVSpeechSynthesisVoice]) -> Binding<String?> {
        Binding(
            get: {
                let id = model.settings.speechVoice
                if id == NaturalVoice.voiceID { return Self.offersNatural ? id : nil }
                return voices.contains { $0.identifier == id } ? id : nil
            },
            set: { model.settings.speechVoice = $0 }
        )
    }

    /// What the voice picker shows: the chosen voice, or "Best available: …".
    private func selectedLabel(_ voices: [AVSpeechSynthesisVoice], showRegion: Bool) -> String {
        let id = voiceSelection(voices).wrappedValue
        if id == NaturalVoice.voiceID { return ReaderSpeechVoices.naturalLabel }
        guard let id, let voice = voices.first(where: { $0.identifier == id }) else {
            return bestLabel(voices, showRegion: showRegion)
        }
        return ReaderSpeechVoices.label(voice, showRegion: showRegion)
    }

    private func bestLabel(_ voices: [AVSpeechSynthesisVoice], showRegion: Bool) -> String {
        if Self.offersNatural { return "Best available: \(ReaderSpeechVoices.naturalLabel)" }
        guard let best = voices.first else { return "Best available" }
        return "Best available: \(ReaderSpeechVoices.label(best, showRegion: showRegion))"
    }
}
