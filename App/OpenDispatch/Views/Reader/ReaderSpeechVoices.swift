import AVFoundation
import NaturalLanguage

/// The system voices Read aloud can use. Premium and Enhanced voices are downloaded in System
/// Settings → Accessibility → Spoken Content (iOS: Settings → Accessibility → Spoken Content → Voices);
/// until then only the compact default ones exist.
enum ReaderSpeechVoices {
    /// Where better voices come from, for Settings' hint.
    static var downloadHint: String {
        #if os(macOS)
        "Better voices download in System Settings → Accessibility → Spoken Content."
        #else
        "Better voices download in Settings → Accessibility → Spoken Content → Voices."
        #endif
    }

    /// The user's language code ("en"), the one voices are listed for.
    static var userLanguage: String { Locale.current.language.languageCode?.identifier ?? "en" }

    /// "en" for "en-US", "yue" for "yue-CN".
    static func languageCode(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// Voices for a language, best first: Premium, then Enhanced, then default; within a quality the
    /// user's own region ("en-US") first, then by name. Novelty voices (Bubbles, Zarvox, the Eloquence
    /// ones) are left out, they are not for reading articles.
    static func available(language: String? = nil) -> [AVSpeechSynthesisVoice] {
        let code = language.map(languageCode) ?? userLanguage
        let region = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { languageCode($0.language) == code && isReadingVoice($0) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == region) != (b.language == region) { return a.language == region }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    private static func isReadingVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) { return false }
        let id = voice.identifier
        return !id.hasPrefix("com.apple.speech.synthesis.voice.") && !id.hasPrefix("com.apple.eloquence.")
    }

    static func best(language: String? = nil) -> AVSpeechSynthesisVoice? {
        available(language: language).first ?? AVSpeechSynthesisVoice(language: language ?? AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// The saved voice if this device has it (and it speaks the article's language), else the best one.
    /// Settings sync between devices, so a voice id from a Mac the iPhone has never downloaded falls back here.
    static func resolve(saved id: String?, language: String? = nil) -> AVSpeechSynthesisVoice? {
        let code = language.map(languageCode)
        if let id, let voice = AVSpeechSynthesisVoice(identifier: id), isReadingVoice(voice),
           code == nil || languageCode(voice.language) == code {
            return voice
        }
        return best(language: code)
    }

    /// The article's language, when it can be told and differs from what the saved voice speaks.
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(800)))
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first, top.value > 0.6 else { return nil }
        return languageCode(top.key.rawValue)
    }

    // MARK: Labels

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }

    /// "Ava (Premium)", with the region when the list mixes them ("Daniel, English (United Kingdom) (Enhanced)").
    static func label(_ voice: AVSpeechSynthesisVoice, showRegion: Bool) -> String {
        var name = voice.name
        if showRegion, let region = Locale.current.localizedString(forIdentifier: voice.language) { name += ", \(region)" }
        return "\(name) (\(qualityLabel(voice)))"
    }

    // MARK: Speed

    /// A speed multiplier (the podcast player's 0.8× to 2×) as AVSpeechUtterance's rate, whose default
    /// 0.5 is 1× and whose scale is not linear: it gets slower faster below the default than it speeds up above.
    static func utteranceRate(forSpeed speed: Float) -> Float {
        let rate = speed <= 1 ? 0.5 + (speed - 1) * 0.5 : 0.5 + (speed - 1) * 0.25
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }
}
