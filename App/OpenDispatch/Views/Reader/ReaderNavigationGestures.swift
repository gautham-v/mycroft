#if os(macOS)
import AppKit
import SwiftUI

/// Back and Forward for the focused reader tab from the trackpad and the mouse, as a browser has them: a horizontal
/// two-finger swipe (when System Settings › Trackpad › Swipe between pages allows it; the page follows `trackSwipeEvent`),
/// a three-finger swipe when that is the setting, and a mouse's back and forward buttons (buttons 4 and 5).
///
/// One local event monitor for the app's windows. A scroll that starts mostly sideways becomes the swipe only when there
/// is somewhere to go that way, so horizontal scrolling elsewhere (a wide code block) still works when there isn't.
@MainActor
final class ReaderNavigationGestures {
    private var monitor: Any?

    func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseUp]) { [weak model] event in
            guard let model, event.window?.attachedSheet == nil else { return event }
            switch event.type {
            case .otherMouseUp:
                // Button numbers count from 0: 3 is a mouse's back button, 4 its forward button.
                if event.buttonNumber == 3, model.canGoBack { model.goBack(); return nil }
                if event.buttonNumber == 4, model.canGoForward { model.goForward(); return nil }
                return event
            case .swipe:
                // A three-finger swipe: fingers moving right (deltaX -1) go back.
                if event.deltaX < 0, model.canGoBack { model.goBack(); return nil }
                if event.deltaX > 0, model.canGoForward { model.goForward(); return nil }
                return event
            case .scrollWheel:
                return Self.trackSwipe(event, model) ? nil : event
            default:
                return event
            }
        }
    }

    /// Starts tracking a two-finger swipe from the first event of a sideways scroll; true when it did.
    private static func trackSwipe(_ event: NSEvent, _ model: AppModel) -> Bool {
        guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return false }
        // Fingers moving right mean back. With natural scrolling the delta follows the fingers; without it, it's reversed.
        let back = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX > 0 : event.scrollingDeltaX < 0
        guard back ? model.canGoBack : model.canGoForward else { return false }
        var done = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: model.canGoForward ? -1 : 0,
                              max: model.canGoBack ? 1 : 0) { amount, phase, _, _ in
            guard phase == .ended, !done else { return }
            done = true
            if amount >= 0.5 { model.goBack() } else if amount <= -0.5 { model.goForward() }
        }
        return true
    }
}
#endif
