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

    public init(itemId: Int64, title: String, publishedAt: Date, sourceId: Int64, sourceTitle: String) {
        self.itemId = itemId
        self.title = title
        self.publishedAt = publishedAt
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
    }
}
