import Foundation
import OpenDispatchCore
import UserNotifications

/// Notifications for new posts from sources with Notify on New Posts on (per device). They are local
/// notifications posted after each refresh: in the app, on the Mac's timer and in iOS background refresh.
/// There is no push server, so they arrive as often as the app refreshes. Tapping one opens the post.
enum PostNotifications {
    /// userInfo key holding the item id.
    static let itemIDKey = "itemID"
    /// One refresh notifies at most this many posts per source; more become one "N new posts" notification.
    static let perSourceLimit = 3

    /// Must be set before launch finishes so a tap that launches the app is delivered (OpenDispatchApp.init).
    static let delegate = PostNotificationDelegate()

    /// Asks the first time; false when notifications are off for the app in Settings.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return true
        }
    }

    /// Posts what's new since the last call (the database hands each post out once). Called after every refresh.
    static func deliver(_ database: AppDatabase) async {
        guard let alerts = try? await database.takeNewPostAlerts(), !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus != .denied else { return }
        for posts in Dictionary(grouping: alerts, by: \.sourceId).values {
            let newest = posts.sorted { $0.publishedAt > $1.publishedAt }
            if newest.count > perSourceLimit, let first = newest.first {
                try? await center.add(request(first, body: "\(newest.count) new posts, latest: \(first.title)"))
            } else {
                for post in newest.reversed() { try? await center.add(request(post, body: post.title)) }
            }
        }
    }

    private static func request(_ post: NewPostAlert, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = post.sourceTitle
        content.body = body
        content.sound = .default
        // Grouped by source in Notification Center.
        content.threadIdentifier = "source-\(post.sourceId)"
        content.userInfo = [itemIDKey: post.itemId]
        return UNNotificationRequest(identifier: "item-\(post.itemId)", content: content, trigger: nil)
    }
}

/// No banner while the app is in front (the list already shows the post); opens a tapped post in the reader.
final class PostNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor weak var model: AppModel?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = (response.notification.request.content.userInfo[PostNotifications.itemIDKey] as? NSNumber)?.int64Value
        else { return }
        await open(id)
    }

    @MainActor private func open(_ itemID: Int64) async {
        await model?.select(itemID: itemID)
    }
}
