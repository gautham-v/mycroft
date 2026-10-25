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

struct AppSettings: Codable, Equatable, Sendable {
    var theme: ThemeSetting = .system
    var readerFont: ReaderFontSetting = .serif
    var textSize: TextSizeSetting = .m
    /// Start playing when you open a video.
    var autoplay: Bool = true
    /// Full-width player above the title.
    var theater: Bool = true

    static let defaults = AppSettings()
    static let storageKey = "openfeed.settings"

    /// Unknown keys and invalid values fall back to defaults (sanitize in use-settings.ts).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(ThemeSetting.self, forKey: .theme)) ?? .system
        readerFont = (try? c.decode(ReaderFontSetting.self, forKey: .readerFont)) ?? .serif
        textSize = (try? c.decode(TextSizeSetting.self, forKey: .textSize)) ?? .m
        autoplay = (try? c.decode(Bool.self, forKey: .autoplay)) ?? true
        theater = (try? c.decode(Bool.self, forKey: .theater)) ?? true
    }

    init() {}

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
