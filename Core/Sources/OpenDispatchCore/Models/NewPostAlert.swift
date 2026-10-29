import Foundation

/// A new post from a source with notifications on (Queries.takeNewPostAlerts); the app posts it as a
/// local notification.
public struct NewPostAlert: Sendable, Hashable {
    /// Older posts a feed adds late (a backdated or re-dated item) don't notify.
    public static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    public var itemId: Int64
    public var title: String
    public var publishedAt: Date
    public var sourceId: Int64
    public var sourceTitle: String
    /// The item's author: for a topic's item, where it comes from (Hacker News, a publisher, a channel, a show).
    public var itemAuthor: String?
    /// The source is a topic, whose `sourceTitle` is the keyword.
    public var isTopic: Bool

    public init(itemId: Int64, title: String, publishedAt: Date, sourceId: Int64, sourceTitle: String,
                itemAuthor: String? = nil, isTopic: Bool = false) {
        self.itemId = itemId
        self.title = title
        self.publishedAt = publishedAt
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.itemAuthor = itemAuthor
        self.isTopic = isTopic
    }

    /// What the notification's title says: the source, or for a topic "<keyword> · <origin>".
    public var heading: String {
        guard isTopic, let origin = itemAuthor?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else { return sourceTitle }
        return sourceTitle + " \u{00B7} " + origin
    }
}
