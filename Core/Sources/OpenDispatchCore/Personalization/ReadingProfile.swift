import Foundation

/// How often the user opens one source, against how much it published (`Queries.readingProfile`).
public struct SourceAffinity: Sendable, Hashable {
    public var opens: Int
    public var published: Int
    /// Doublings above (or below) the user's overall open rate, blended toward zero while there is little to go on.
    public var lift: Double

    public init(opens: Int, published: Int, lift: Double) {
        self.opens = opens
        self.published = published
        self.lift = lift
    }
}

/// What For You order knows about the user: an affinity per source, by feed URL, counted on the device from History
/// (which syncs, so opens on another device count too). Nothing about it leaves the device.
public struct ReadingProfile: Sendable, Hashable {
    /// How far back it looks. Items are pruned after 14 days, so a longer window would count opens without their rows.
    public static let window: TimeInterval = 14 * 86_400
    /// Rows of evidence a source needs before its own rate outweighs the overall one: a new or quiet source starts at the
    /// user's average, so For You stays close to Balanced until there is something to go on.
    public static let blendRows = 20.0
    /// Hours of head start for a source opened twice as often as average, the strength tested on real reading.
    public static let hoursPerDoubling = 6.0
    /// The most a row's time moves either way, so recency keeps deciding most of the order.
    public static let maxShiftHours = 12.0

    public var affinities: [String: SourceAffinity]

    public init(affinities: [String: SourceAffinity] = [:]) {
        self.affinities = affinities
    }

    public static let empty = ReadingProfile()

    /// How many hours newer (or, negative, older) a row of this source counts. `preference` is the row menu's Show More
    /// (+1) or Show Less (-1), which moves it as far as doubling or halving the open rate would.
    public func shiftHours(feedUrl: String, preference: Int = 0) -> Double {
        let lift = (affinities[feedUrl]?.lift ?? 0) + Double(preference)
        return min(Self.maxShiftHours, max(-Self.maxShiftHours, lift * Self.hoursPerDoubling))
    }

    /// The affinity from counts, given the overall rate.
    static func lift(opens: Int, published: Int, overall: Double) -> Double {
        let rate = (Double(opens) + blendRows * overall) / (Double(published) + blendRows)
        return log2(rate / overall)
    }
}
