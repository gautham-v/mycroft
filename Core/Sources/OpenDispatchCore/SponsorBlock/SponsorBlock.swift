import Foundation

/// A SponsorBlock segment category (https://wiki.sponsor.ajay.app/w/Types). Raw values are SponsorBlock's ids.
public enum SponsorBlockCategory: String, Sendable, CaseIterable, Identifiable, Hashable {
    case sponsor, selfpromo, interaction, intro, outro, preview, hook, filler
    case musicOfftopic = "music_offtopic"
    case poiHighlight = "poi_highlight"
    case exclusiveAccess = "exclusive_access"

    public var id: String { rawValue }

    /// Settings title.
    public var title: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-promotion"
        case .interaction: "Interaction reminder"
        case .intro: "Intro"
        case .outro: "Endcards and credits"
        case .preview: "Preview and recap"
        case .hook: "Hook"
        case .filler: "Filler and tangents"
        case .musicOfftopic: "Non-music section"
        case .poiHighlight: "Highlight"
        case .exclusiveAccess: "Exclusive access"
        }
    }

    /// One line under the title in Settings.
    public var summary: String {
        switch self {
        case .sponsor: "Paid promotion, paid referrals and direct advertisements"
        case .selfpromo: "Unpaid promotion of the creator's own merch, donations or other channels"
        case .interaction: "Reminders to like, subscribe or follow"
        case .intro: "An intro animation or intermission with no real content"
        case .outro: "Endcards, credits and the closing sign-off"
        case .preview: "A recap of earlier parts or a preview of what's coming"
        case .hook: "A teaser of the video, or the greeting before it starts"
        case .filler: "Tangents, jokes and other scenes that aren't needed to follow the video"
        case .musicOfftopic: "Parts of a music video that aren't music"
        case .poiHighlight: "The moment most viewers are looking for"
        case .exclusiveAccess: "The whole video is a sponsored or paid-access showcase"
        }
    }

    /// The lowercase noun phrase the player's toast uses ("Skipped sponsor").
    public var label: String {
        switch self {
        case .sponsor: "sponsor"
        case .selfpromo: "self-promotion"
        case .interaction: "interaction reminder"
        case .intro: "intro"
        case .outro: "endcards"
        case .preview: "preview"
        case .hook: "hook"
        case .filler: "filler"
        case .musicOfftopic: "non-music section"
        case .poiHighlight: "highlight"
        case .exclusiveAccess: "exclusive access"
        }
    }

    /// SponsorBlock's color for the category, as a CSS hex.
    public var colorHex: String {
        switch self {
        case .sponsor: "#00d400"
        case .selfpromo: "#ffff00"
        case .exclusiveAccess: "#008a5c"
        case .interaction: "#cc00ff"
        case .intro: "#00ffff"
        case .outro: "#0202ed"
        case .preview: "#008fd6"
        case .hook: "#395699"
        case .filler: "#7300ff"
        case .musicOfftopic: "#ff9900"
        case .poiHighlight: "#ff1684"
        }
    }

    /// The modes Settings offers. A highlight is a point and exclusive access labels the whole video, so
    /// neither can be skipped or muted; a non-music section can't be muted.
    public var allowedModes: [SponsorBlockMode] {
        switch self {
        case .poiHighlight, .exclusiveAccess: [.show, .off]
        case .musicOfftopic: [.skip, .show, .off]
        default: [.skip, .mute, .show, .off]
        }
    }

    public var defaultMode: SponsorBlockMode {
        switch self {
        case .sponsor, .selfpromo, .interaction: .skip
        case .intro, .outro, .preview, .hook, .poiHighlight, .exclusiveAccess: .show
        case .filler, .musicOfftopic: .off
        }
    }

    /// `mode` if Settings offers it for this category, else the default (a synced or older value).
    public func resolved(_ mode: SponsorBlockMode?) -> SponsorBlockMode {
        guard let mode, allowedModes.contains(mode) else { return defaultMode }
        return mode
    }
}

/// What the player does with a category's segments.
public enum SponsorBlockMode: String, Sendable, CaseIterable, Identifiable, Hashable, Codable {
    case skip, mute, show, off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skip: "Skip"
        case .mute: "Mute"
        case .show: "Show on bar"
        case .off: "Off"
        }
    }
}

/// A segment as SponsorBlock lists it.
public struct SponsorBlockSegment: Sendable, Hashable {
    public var start: Double
    public var end: Double
    /// A `SponsorBlockCategory` raw value.
    public var category: String
    /// SponsorBlock's action type: skip, mute, full or poi.
    public var actionType: String
    public var uuid: String
    /// The length of the video the segment was submitted for (0 if unknown); the page drops segments that no longer fit.
    public var videoDuration: Double

    public init(start: Double, end: Double, category: String, actionType: String = "skip", uuid: String = "", videoDuration: Double = 0) {
        self.start = start
        self.end = end
        self.category = category
        self.actionType = actionType
        self.uuid = uuid
        self.videoDuration = videoDuration
    }
}

/// A segment as the player page takes it (`window.odPlayer.setSegments`).
public struct SponsorBlockPlayerSegment: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Codable { case skip, mute, show, full, poi }

    public var start: Double
    public var end: Double
    public var category: String
    public var action: Action
    /// Lowercase noun phrase for the toast.
    public var label: String
    /// CSS hex.
    public var color: String
    public var videoDuration: Double
}

public protocol SponsorBlockFetching: Sendable {
    /// The video's segments in every category; empty when it has none or SponsorBlock can't be reached.
    func segments(forVideoID videoID: String) async -> [SponsorBlockSegment]
}

public enum SponsorBlock {
    /// The segments the player acts on under `mode`: categories set to Off are left out, the rest get the
    /// action the mode and SponsorBlock's action type give them, ordered by start.
    public static func playerSegments(
        _ segments: [SponsorBlockSegment], mode: (SponsorBlockCategory) -> SponsorBlockMode
    ) -> [SponsorBlockPlayerSegment] {
        var out: [SponsorBlockPlayerSegment] = []
        for s in segments {
            guard let category = SponsorBlockCategory(rawValue: s.category), s.start.isFinite, s.end.isFinite, s.start >= 0 else { continue }
            let mode = category.resolved(mode(category))
            guard mode != .off else { continue }
            let action: SponsorBlockPlayerSegment.Action
            if category == .poiHighlight || s.actionType == "poi" {
                action = .poi
            } else if s.actionType == "full" || category == .exclusiveAccess {
                action = .full
            } else if s.end <= s.start {
                continue
            } else if mode == .show {
                action = .show
            } else {
                // A segment submitted as a mute stays a mute even where the category is set to Skip.
                action = mode == .mute || s.actionType == "mute" ? .mute : .skip
            }
            out.append(SponsorBlockPlayerSegment(
                start: s.start, end: action == .poi ? s.start : s.end, category: s.category, action: action,
                label: category.label, color: category.colorHex, videoDuration: max(0, s.videoDuration)))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// `playerSegments` as the JSON array the page takes.
    public static func playerJSON(_ segments: [SponsorBlockPlayerSegment]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(segments), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
