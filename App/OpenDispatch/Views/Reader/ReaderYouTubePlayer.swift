import OpenDispatchCore
import SwiftUI
import WebKit

/// 16:9 (9:16 for a Short) youtube-nocookie embed with our own controls (ReaderYouTubePage). The embed sits in a tiny
/// local page whose origin identifies the app, because YouTube refuses embeds without a referrer.
///
/// Until playback starts the video's thumbnail covers the player, so YouTube's own poster never shows.
/// With autoplay off it carries a play button and the length, and YouTube isn't loaded until it's
/// pressed; with autoplay on it shows a spinner until the first frame plays.
struct ReaderYouTubePlayer: View {
    let videoID: String
    let title: String
    let autoplay: Bool
    var thumbnail: String?
    var durationSec: Int?
    var vertical = false

    var body: some View {
        ReaderYouTubeStage(videoID: videoID, title: title, autoplay: autoplay, thumbnail: thumbnail,
                           durationSec: durationSec, vertical: vertical)
            .aspectRatio(vertical ? 9 / 16 : 16 / 9, contentMode: .fit)
            .background(Color.black)
            .id(videoID)
            .accessibilityLabel(title)
    }
}

private struct ReaderYouTubeStage: View {
    let videoID: String
    let title: String
    let thumbnail: String?
    let durationSec: Int?
    let vertical: Bool

    @State private var started: Bool
    /// The poster is gone: playback started, or the player failed or took too long and is shown as is.
    @State private var revealed = false
    @State private var controller = ReaderYouTubeController()
    #if os(iOS)
    @State private var fullscreen: ReaderYouTubeFullscreenStart?
    #endif

    init(videoID: String, title: String, autoplay: Bool, thumbnail: String?, durationSec: Int?, vertical: Bool) {
        self.videoID = videoID
        self.title = title
        self.thumbnail = thumbnail
        self.durationSec = durationSec
        self.vertical = vertical
        _started = State(initialValue: autoplay)
    }

    var body: some View {
        ZStack {
            if started {
                ReaderYouTubeRepresentable(videoID: videoID, title: title, start: 0, inCover: false,
                                           controller: controller, onEvent: handle)
            }
            if !revealed {
                ReaderYouTubePoster(videoID: videoID, title: title, thumbnail: thumbnail, durationSec: durationSec,
                                    vertical: vertical, loading: started) { started = true }
                    .transition(.opacity)
            }
        }
        .onAppear {
            controller.start = { started = true }
            ReaderYouTubeController.current = controller
        }
        .onDisappear {
            if ReaderYouTubeController.current === controller { ReaderYouTubeController.current = nil }
        }
        .task(id: started) {
            // Autoplay refused or a slow network: hand over to the player (and its play button) after a while.
            guard started, !revealed, (try? await Task.sleep(for: .seconds(8))) != nil else { return }
            reveal()
        }
        #if os(iOS)
        .fullScreenCover(item: $fullscreen) { start in
            ReaderYouTubeFullscreen(videoID: videoID, title: title, start: start.time, vertical: vertical) { time in
                fullscreen = nil
                controller.resume(at: time)
            }
        }
        #endif
    }

    private func reveal() {
        withAnimation(.easeOut(duration: 0.2)) { revealed = true }
    }

    private func handle(_ event: ReaderYouTubeEvent) {
        switch event {
        case .playing, .failed: reveal()
        #if os(iOS)
        case .fullscreen(let time): fullscreen = ReaderYouTubeFullscreenStart(time: time)
        #else
        case .fullscreen: break
        #endif
        case .exitFullscreen: break
        }
    }
}

/// The thumbnail over the player before it plays: YouTube's largest frame (maxresdefault, which not
/// every video has; oar2, the full 9:16 frame, for a Short), else the feed's thumbnail.
private struct ReaderYouTubePoster: View {
    let videoID: String
    let title: String
    let thumbnail: String?
    let durationSec: Int?
    let vertical: Bool
    let loading: Bool
    let play: () -> Void

    @State private var hovering = false

    private var id: String { videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoID }
    private var fallbackURL: URL? {
        if let thumbnail, !thumbnail.isEmpty { return URL(string: thumbnail) }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    var body: some View {
        Button { if !loading { play() } } label: {
            Color.black
                .overlay { image }
                .overlay { button }
                .overlay(alignment: .bottomTrailing) {
                    if !loading, let duration = TextFormat.duration(durationSec) {
                        Text(duration)
                            .font(OFFont.ui(12, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(12)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(loading ? "Loading \(title)" : "Play \(title)")
    }

    private var image: some View {
        CachedAsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(id)/\(vertical ? "oar2" : "maxresdefault").jpg"),
                         maxPixelSize: 1280) { image in
            image.resizable().scaledToFill()
        } placeholder: { failed in
            if failed {
                CachedAsyncImage(url: fallbackURL, maxPixelSize: 1280) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.black
                }
            } else {
                Color.black
            }
        }
    }

    private var button: some View {
        Circle()
            .fill(Color.black.opacity(hovering && !loading ? 0.6 : 0.42))
            .background(.ultraThinMaterial, in: Circle())
            .frame(width: 64, height: 64)
            .overlay {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    OFIcon.play.image
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            }
            .environment(\.colorScheme, .dark)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

#if os(iOS)
private struct ReaderYouTubeFullscreenStart: Identifiable {
    let id = UUID()
    let time: Double
}

/// iPhone full screen (WebKit has no element full screen there): a second player in a cover, started
/// where the first one paused. Its exit button reports the time back so the reader's player carries on.
private struct ReaderYouTubeFullscreen: View {
    let videoID: String
    let title: String
    let start: Double
    let vertical: Bool
    let onExit: (Double) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ReaderYouTubeRepresentable(videoID: videoID, title: title, start: Int(start), inCover: true, controller: nil) { event in
                switch event {
                case .exitFullscreen(let time): onExit(time)
                case .failed: onExit(start)
                default: break
                }
            }
            .aspectRatio(vertical ? 9 / 16 : 16 / 9, contentMode: .fit)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
#endif

enum ReaderYouTubeEvent {
    case playing, failed, fullscreen(Double), exitFullscreen(Double)
}

/// Lets the stage reach the player's page (resume after the iPhone full-screen cover closes), and the
/// window's key monitor reach the reader's player (Space plays or pauses it and ←/→ skip wherever focus is).
@MainActor
final class ReaderYouTubeController {
    /// The player in the reader, if it shows a video (the most recent one, with several panes).
    static weak var current: ReaderYouTubeController?

    weak var webView: WKWebView?
    /// Presses the poster's play button (before the player is loaded).
    var start: (() -> Void)?

    func togglePlayback() {
        if let webView {
            webView.evaluateJavaScript("window.odPlayer && window.odPlayer.toggle()")
        } else {
            start?()
        }
    }

    /// Skips by `seconds` (negative goes back). Nothing before the player is loaded.
    func seek(by seconds: Double) {
        webView?.evaluateJavaScript("window.odPlayer && window.odPlayer.seekBy(\(seconds))")
    }

    func resume(at time: Double) {
        webView?.evaluateJavaScript("window.odPlayer && window.odPlayer.resume(\(time))")
    }
}

enum ReaderYouTube {
    /// Origin of the wrapper page (sent as the Referer); YouTube asks WebView apps to use their bundle id
    /// (com.gauthamv.openfeed, which keeps the app's original name).
    static let origin = "https://com.gauthamv.openfeed"
    static let pageOrigin = URL(string: origin + "/")

    /// YouTube's controls off (ours replace them), captions and cards off, and the IFrame API on.
    static func embedURL(videoID: String, start: Int) -> String {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoID
        let from = start > 0 ? "&start=\(start)" : ""
        return "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&controls=0&rel=0&playsinline=1&iv_load_policy=3"
            + "&cc_load_policy=0&disablekb=1&fs=0&enablejsapi=1&origin=\(origin)\(from)"
    }

    @MainActor static func page(videoID: String, title: String, start: Int, inCover: Bool) -> String {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoID
        #if os(iOS)
        let nativeFullscreen = true
        #else
        let nativeFullscreen = false
        #endif
        return ReaderYouTubePage.html(
            src: ReaderWebSupport.escapeAttribute(embedURL(videoID: videoID, start: start)),
            title: ReaderWebSupport.escapeAttribute(title),
            poster: ReaderWebSupport.escapeAttribute("https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
            nativeFullscreen: nativeFullscreen, inCover: inCover)
    }
}

@MainActor
final class ReaderYouTubeCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var loadedKey: String?
    var onEvent: (ReaderYouTubeEvent) -> Void = { _ in }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ReaderWebSupport.policy(for: navigationAction, documentURL: ReaderYouTube.pageOrigin))
    }

    /// Links inside the player (YouTube's error page) open in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { ReaderWebSupport.openExternally(url) }
        return nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let time = (body["time"] as? NSNumber)?.doubleValue ?? 0
        switch type {
        case "playing": onEvent(.playing)
        case "failed": onEvent(.failed)
        case "fullscreen": onEvent(.fullscreen(time))
        case "exitFullscreen": onEvent(.exitFullscreen(time))
        default: break
        }
    }

    /// Autoplay is always allowed: the web view only exists once playback is wanted (autoplay on, or the
    /// poster's play button pressed).
    func makeWebView() -> WKWebView {
        let config = ReaderWebSupport.configuration(autoplay: true)
        config.userContentController.add(ReaderWeakScriptHandler(self), name: ReaderYouTubePage.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: ReaderYouTubePage.frameStyleScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: config)
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

    func update(_ webView: WKWebView, videoID: String, title: String, start: Int, inCover: Bool) {
        let key = "\(videoID)|\(start)|\(inCover)"
        guard key != loadedKey else { return }
        loadedKey = key
        webView.loadHTMLString(ReaderYouTube.page(videoID: videoID, title: title, start: start, inCover: inCover),
                               baseURL: ReaderYouTube.pageOrigin)
    }

    func dismantle(_ webView: WKWebView) {
        // Stop playback when the reader moves on.
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ReaderYouTubePage.handlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

#if os(macOS)
private struct ReaderYouTubeRepresentable: NSViewRepresentable {
    let videoID: String
    let title: String
    let start: Int
    let inCover: Bool
    let controller: ReaderYouTubeController?
    let onEvent: (ReaderYouTubeEvent) -> Void

    func makeCoordinator() -> ReaderYouTubeCoordinator { ReaderYouTubeCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView()
        controller?.webView = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.update(view, videoID: videoID, title: title, start: start, inCover: inCover)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: ReaderYouTubeCoordinator) {
        coordinator.dismantle(view)
    }
}
#else
private struct ReaderYouTubeRepresentable: UIViewRepresentable {
    let videoID: String
    let title: String
    let start: Int
    let inCover: Bool
    let controller: ReaderYouTubeController?
    let onEvent: (ReaderYouTubeEvent) -> Void

    func makeCoordinator() -> ReaderYouTubeCoordinator { ReaderYouTubeCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView()
        controller?.webView = view
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.update(view, videoID: videoID, title: title, start: start, inCover: inCover)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: ReaderYouTubeCoordinator) {
        coordinator.dismantle(view)
    }
}
#endif
