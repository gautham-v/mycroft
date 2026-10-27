import Foundation
import SwiftUI

/// Port of src/hooks/use-settings.ts. Persisted as JSON in UserDefaults under `openfeed.settings`.
enum ThemeSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// For `.preferredColorScheme(_:)`; nil follows the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ReaderFontSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case serif, sans
    var id: String { rawValue }
    var label: String { self == .serif ? "Serif" : "Sans" }
}

enum TextSizeSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case s, m, l
    var id: String { rawValue }
    var label: String {
        switch self {
        case .s: "Small"
        case .m: "Medium"
        case .l: "Large"
        }
    }
}

/// Reader column cap (Settings → Appearance → Reader width).
enum ReaderWidthSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case narrow, medium, wide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        case .wide: "Wide"
        }
    }
    /// Text column width; the side padding sits outside it. Medium is the original 640.
    var points: CGFloat {
        switch self {
        case .narrow: 560
        case .medium: 640
        case .wide: 800
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var theme: ThemeSetting = .system
    var readerFont: ReaderFontSetting = .sans
    var textSize: TextSizeSetting = .m
    var readerWidth: ReaderWidthSetting = .medium
    /// The article column uses the whole reader pane, ignoring `readerWidth`.
    var fillWindow: Bool = false
    /// Start playing when you open a video.
    var autoplay: Bool = true
    /// Full-width player above the title.
    var theater: Bool = true
    /// Copy as Markdown: a line put above the copied text (Settings → Integrations). Empty = none.
    var copyPrompt: String = ""

    static let defaults = AppSettings()
    // UserDefaults keys keep the app's original name (openfeed.*) so existing settings carry over.
    static let storageKey = "openfeed.settings"
    /// Set once the reader font default moved to Sans (1.0.6); settings saved before then carry Serif.
    private static let sansDefaultKey = "openfeed.settings.sans-default"

    /// Unknown keys and invalid values fall back to defaults (sanitize in use-settings.ts).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(ThemeSetting.self, forKey: .theme)) ?? .system
        readerFont = (try? c.decode(ReaderFontSetting.self, forKey: .readerFont)) ?? .sans
        textSize = (try? c.decode(TextSizeSetting.self, forKey: .textSize)) ?? .m
        readerWidth = (try? c.decode(ReaderWidthSetting.self, forKey: .readerWidth)) ?? .medium
        fillWindow = (try? c.decode(Bool.self, forKey: .fillWindow)) ?? false
        autoplay = (try? c.decode(Bool.self, forKey: .autoplay)) ?? true
        theater = (try? c.decode(Bool.self, forKey: .theater)) ?? true
        copyPrompt = (try? c.decode(String.self, forKey: .copyPrompt)) ?? ""
    }

    init() {}

    /// The reader's text column cap; nil with Fill window (the pane's width minus its side padding).
    var readerColumnWidth: CGFloat? { fillWindow ? nil : readerWidth.points }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              var s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        // Saved settings hold the old Serif default whether or not it was picked: switch them to Sans once.
        if !defaults.bool(forKey: sansDefaultKey) {
            defaults.set(true, forKey: sansDefaultKey)
            s.readerFont = .sans
            s.save(to: defaults)
        }
        return s
    }

    /// The copy iCloud sync carries (MetaKey.syncedSettings). Sorted keys, so equal settings give equal text.
    var syncJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    init?(syncJSON: String) {
        guard let s = try? JSONDecoder().decode(AppSettings.self, from: Data(syncJSON.utf8)) else { return nil }
        self = s
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
