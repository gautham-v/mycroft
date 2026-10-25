import Foundation
import OpenfeedCore
#if os(iOS)
import BackgroundTasks
#endif

/// iOS background app refresh (BGAppRefreshTask "com.gauthamv.openfeed.refresh"). The SwiftUI scene
/// handles the task with `.backgroundTask(.appRefresh(BackgroundRefresh.identifier))` in OpenfeedApp;
/// RootView calls `schedule()` when the app moves to the background. macOS refreshes on foreground only.
enum BackgroundRefresh {
    static let identifier = "com.gauthamv.openfeed.refresh"
    /// Ask to run no sooner than this (feeds are stale after 15 min).
    static let interval: TimeInterval = 30 * 60

    static func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// Body of the background task: a non-forced refresh, then schedule the next one.
    static func run(_ services: OpenfeedServices) async {
        schedule()
        _ = try? await services.refresh.refreshAll(force: false)
    }
}
