import Foundation

/// Port of src/lib/time.ts.
public enum RelativeTime {
    /// Refresh runs when the last one is older than this (15 min).
    public static let staleInterval: TimeInterval = 15 * 60

    /// Compact relative time: "now", "23m", "3h", "2d", "5w", "2y".
    public static func format(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(floor(now.timeIntervalSince(date))))
        if s < 60 { return "now" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        if d < 365 { return "\(d / 7)w" }
        return "\(d / 365)y"
    }

    /// "updated just now" / "updated 5m ago" / "updated never" (the list header subline).
    public static func updatedLabel(_ last: Date?, now: Date = Date()) -> String {
        guard let last else { return "updated never" }
        let r = format(last, now: now)
        return r == "now" ? "updated just now" : "updated \(r) ago"
    }

    public static func isStale(_ last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) > staleInterval
    }
}
