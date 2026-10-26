import Foundation
import OpenDispatchCore
#if os(iOS)
import BackgroundTasks
#endif

/// iOS background app refresh (BGAppRefreshTask "com.gauthamv.openfeed.refresh"). The SwiftUI scene
/// handles the task with `.backgroundTask(.appRefresh(BackgroundRefresh.identifier))` in OpenDispatchApp;
/// RootView calls `schedule()` when the app moves to the background. macOS refreshes on foreground only.
enum BackgroundRefresh {
    // Must match BGTaskSchedulerPermittedIdentifiers in project.yml; keeps the bundle id's original name.
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
    static func run(_ services: OpenDispatchServices) async {
        schedule()
        _ = try? await services.refresh.refreshAll(force: false)
    }
}
