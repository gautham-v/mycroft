import Foundation

/// ISO 8601 helpers matching JavaScript's `Date.prototype.toISOString()` ("2026-10-25T12:00:00.000Z").
public enum ISO8601 {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func string(from date: Date) -> String {
        date.formatted(withFraction)
    }

    /// Parses with or without fractional seconds. nil when not ISO 8601.
    public static func date(from string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        if let d = try? withFraction.parse(s) { return d }
        return try? plain.parse(s)
    }
}
