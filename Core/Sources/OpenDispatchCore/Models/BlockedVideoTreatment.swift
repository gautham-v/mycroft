import Foundation

/// What the lists do with videos whose owner keeps them out of other apps (Settings → Playback → Videos that won't play here).
public enum BlockedVideoTreatment: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Listed like any video; the player tries and falls back to its notice.
    case show
    /// A row names YouTube and opens there, and the reader shows its notice without trying the player.
    case mark
    /// As Mark, and they leave the lists other than Saved and a search.
    case hide

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .show: "Show"
        case .mark: "Mark"
        case .hide: "Hide"
        }
    }
}
