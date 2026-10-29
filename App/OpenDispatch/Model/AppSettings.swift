import Foundation
import OpenDispatchCore
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

/// Reader typeface. `serif` is New York (the system serif); Charter and Iowan Old Style ship with macOS
/// and iOS, so nothing is bundled.
enum ReaderFontSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case sans, serif, charter, iowan
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sans: "Sans"
        case .serif: "New York"
        case .charter: "Charter"
        case .iowan: "Iowan"
        }
    }
}

/// Reader text size, eight steps (OFFont.bodySize). s / m / l keep their original sizes and raw values,
/// so saved settings carry over.
enum TextSizeSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case xxs, xs, s, m, l, xl, xxl, xxxl
    var id: String { rawValue }
    var label: String { "\(OFFont.bodySize(self).formatted()) pt" }

    /// The next step down or up, nil at either end.
    var smaller: TextSizeSetting? { step(-1) }
    var larger: TextSizeSetting? { step(1) }

    private func step(_ d: Int) -> TextSizeSetting? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), all.indices.contains(i + d) else { return nil }
        return all[i + d]
    }
}

/// Reader line height (reader.css data-leading).
enum LineSpacingSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case tight, normal, loose
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tight: "Tight"
        case .normal: "Normal"
        case .loose: "Loose"
        }
    }
    /// Line height as a multiple of the font size.
    var lineHeight: CGFloat {
        switch self {
        case .tight: 1.45
        case .normal: 1.6
        case .loose: 1.8
        }
    }
}

/// Settings → Appearance → Feed order.
extension FeedOrder {
    var label: String {
        switch self {
        case .latest: "Latest"
        case .balanced: "Balanced"
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
    var lineSpacing: LineSpacingSetting = .normal
    var readerWidth: ReaderWidthSetting = .medium
    /// The article column uses the whole reader pane, ignoring `readerWidth`.
    var fillWindow: Bool = false
    /// Start playing when you open a video.
    var autoplay: Bool = true
    /// Full-width player above the title.
    var theater: Bool = true
    /// The captions under a video, following along as it plays.
    var videoTranscript: Bool = true
    /// The transcript under a video is folded to its heading.
    var videoTranscriptCollapsed: Bool = false
    /// Act on SponsorBlock segments in YouTube videos (Settings → Playback → SponsorBlock).
    var sponsorBlock: Bool = true
    /// What the player does per category, by SponsorBlock id, for the ones changed from their default.
    var sponsorBlockModes: [String: SponsorBlockMode] = [:]
    /// Copy as Markdown: a line put above the copied text (Settings → Integrations). Empty = none.
    var copyPrompt: String = ""
    /// Read aloud voice (AVSpeechSynthesisVoice identifier); nil is the best voice installed. Another
    /// device's voice may not exist here, so readers resolve it through `ReaderSpeechVoices.resolve`.
    var speechVoice: String?
    /// Read aloud speed multiplier at the start of each article (one of the podcast player's steps).
    var speechRate: Float = 1
    /// Send highlights and notes made on this device to Readwise (when a token is set).
    var sendHighlightsToReadwise: Bool = true
    /// How All, its Articles, Posts, Video and Podcasts views, and topics order items (`AppModel.listOrder`).
    var feedOrder: FeedOrder = .balanced
    /// Leave read items out of the lists (not Saved or searches); they stay in History.
    var hideReadItems: Bool = false
    /// The comments under a post, a video or an article's Hacker News discussion, and the reader's Discussion link.
    /// Off, the reader builds none of them, so nothing is fetched.
    var showComments: Bool = true
    /// What the lists do with articles from paywalled sites you aren't signed in to (Settings → Integrations).
    var paywallTreatment: PaywallTreatment = .mark
    /// The sites that have walled an article, and which ones stopped being asked about; synced with the settings.
    var paywalls = PaywallBook()

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
        lineSpacing = (try? c.decode(LineSpacingSetting.self, forKey: .lineSpacing)) ?? .normal
        readerWidth = (try? c.decode(ReaderWidthSetting.self, forKey: .readerWidth)) ?? .medium
        fillWindow = (try? c.decode(Bool.self, forKey: .fillWindow)) ?? false
        autoplay = (try? c.decode(Bool.self, forKey: .autoplay)) ?? true
        theater = (try? c.decode(Bool.self, forKey: .theater)) ?? true
        videoTranscript = (try? c.decode(Bool.self, forKey: .videoTranscript)) ?? true
        videoTranscriptCollapsed = (try? c.decode(Bool.self, forKey: .videoTranscriptCollapsed)) ?? false
        sponsorBlock = (try? c.decode(Bool.self, forKey: .sponsorBlock)) ?? true
        // Values this build doesn't know (or a category's disallowed mode) are dropped, so the default applies.
        let modes = (try? c.decode([String: String].self, forKey: .sponsorBlockModes)) ?? [:]
        for category in SponsorBlockCategory.allCases {
            if let mode = modes[category.rawValue].flatMap(SponsorBlockMode.init(rawValue:)), category.allowedModes.contains(mode) {
                sponsorBlockModes[category.rawValue] = mode
            }
        }
        copyPrompt = (try? c.decode(String.self, forKey: .copyPrompt)) ?? ""
        speechVoice = (try? c.decodeIfPresent(String.self, forKey: .speechVoice)) ?? nil
        let rate = (try? c.decode(Float.self, forKey: .speechRate)) ?? 1
        speechRate = ReaderPodcastPlayback.rates.contains(rate) ? rate : 1
        sendHighlightsToReadwise = (try? c.decode(Bool.self, forKey: .sendHighlightsToReadwise)) ?? true
        feedOrder = (try? c.decode(FeedOrder.self, forKey: .feedOrder)) ?? .balanced
        hideReadItems = (try? c.decode(Bool.self, forKey: .hideReadItems)) ?? false
        showComments = (try? c.decode(Bool.self, forKey: .showComments)) ?? true
        paywallTreatment = (try? c.decode(PaywallTreatment.self, forKey: .paywallTreatment)) ?? .mark
        paywalls = (try? c.decode(PaywallBook.self, forKey: .paywalls)) ?? PaywallBook()
    }

    init() {}

    func sponsorBlockMode(_ category: SponsorBlockCategory) -> SponsorBlockMode {
        category.resolved(sponsorBlockModes[category.rawValue])
    }

    /// Stores a mode; the category's default is not kept, so a future change to a default reaches everyone who never touched it.
    mutating func setSponsorBlockMode(_ mode: SponsorBlockMode, for category: SponsorBlockCategory) {
        sponsorBlockModes[category.rawValue] = mode == category.defaultMode ? nil : mode
    }

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
