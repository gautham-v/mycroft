import SwiftUI
import WebKit

/// 16:9 youtube-nocookie embed (port of the iframe in reader.tsx VideoBody). The embed sits in a tiny
/// local page whose origin identifies the app, because YouTube refuses embeds without a referrer.
struct ReaderYouTubePlayer: View {
    let videoID: String
    let title: String
    let autoplay: Bool

    var body: some View {
        ReaderYouTubeRepresentable(videoID: videoID, title: title, autoplay: autoplay)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color.black)
            .id(videoID)
            .accessibilityLabel(title)
    }
}

enum ReaderYouTube {
    /// Origin of the wrapper page (sent as the Referer); YouTube asks WebView apps to use their bundle id
    /// (com.gauthamv.openfeed, which keeps the app's original name).
    static let pageOrigin = URL(string: "https://com.gauthamv.openfeed/")

    static func embedURL(videoID: String, autoplay: Bool) -> String {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoID
        return "https://www.youtube-nocookie.com/embed/\(id)?\(autoplay ? "autoplay=1&" : "")rel=0&playsinline=1"
    }

    @MainActor static func page(videoID: String, title: String, autoplay: Bool) -> String {
        let src = ReaderWebSupport.escapeAttribute(embedURL(videoID: videoID, autoplay: autoplay))
        let t = ReaderWebSupport.escapeAttribute(title)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><iframe src="\(src)" title="\(t)"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
    }
}

@MainActor
final class ReaderYouTubeCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var loadedKey: String?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ReaderWebSupport.policy(for: navigationAction, documentURL: ReaderYouTube.pageOrigin))
    }

    /// "Watch on YouTube" and other links inside the player open in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { ReaderWebSupport.openExternally(url) }
        return nil
    }

    func makeWebView(autoplay: Bool) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: ReaderWebSupport.configuration(autoplay: autoplay))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        #endif
        return webView
    }

    func update(_ webView: WKWebView, videoID: String, title: String, autoplay: Bool) {
        let key = "\(videoID)|\(autoplay)"
        guard key != loadedKey else { return }
        loadedKey = key
        webView.loadHTMLString(ReaderYouTube.page(videoID: videoID, title: title, autoplay: autoplay),
                               baseURL: ReaderYouTube.pageOrigin)
    }
}

#if os(macOS)
private struct ReaderYouTubeRepresentable: NSViewRepresentable {
    let videoID: String
    let title: String
    let autoplay: Bool

    func makeCoordinator() -> ReaderYouTubeCoordinator { ReaderYouTubeCoordinator() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView(autoplay: autoplay) }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view, videoID: videoID, title: title, autoplay: autoplay)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: ReaderYouTubeCoordinator) {
        // Stop playback when the reader moves on.
        view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
#else
private struct ReaderYouTubeRepresentable: UIViewRepresentable {
    let videoID: String
    let title: String
    let autoplay: Bool

    func makeCoordinator() -> ReaderYouTubeCoordinator { ReaderYouTubeCoordinator() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView(autoplay: autoplay) }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view, videoID: videoID, title: title, autoplay: autoplay)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: ReaderYouTubeCoordinator) {
        view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
#endif
