#if os(iOS)
import SwiftUI
import UIKit

/// iPhone reader's Share button: the system share sheet for the item's link, with Copy as Markdown among
/// its actions (ShareLink can't add one).
enum ItemShareSheet {
    @MainActor static func present(url: URL, title: String, onCopyMarkdown: @escaping @MainActor @Sendable () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [ShareItem(url: url, title: title)],
                                             applicationActivities: [CopyMarkdownActivity(action: onCopyMarkdown)])
        // iPad presents it as a popover; anchor it to the top trailing corner, where the button is.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 44, y: top.view.safeAreaInsets.top, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}

/// The link, with the title as the subject (Mail) — what ShareLink(item:subject:) shared.
private final class ShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String { title }
}

private final class CopyMarkdownActivity: UIActivity {
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("com.gauthamv.openfeed.copy-markdown") }
    override var activityTitle: String? { "Copy as Markdown" }
    override var activityImage: UIImage? { UIImage(systemName: "doc.on.doc") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    /// UIKit calls this on the main thread.
    override func perform() {
        let action = self.action
        MainActor.assumeIsolated { action() }
        activityDidFinish(true)
    }
}
#endif
