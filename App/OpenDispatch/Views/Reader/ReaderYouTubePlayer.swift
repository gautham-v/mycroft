import OpenDispatchCore
import SwiftUI
import WebKit
#if os(iOS)
import AVFoundation
#endif

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
    /// Where a video watched partway starts again (History); nil starts at the beginning.
    var resumeAt: Double?
    /// Shared with the transcript, which follows the position and seeks through it.
    let controller: ReaderYouTubeController

    var body: some View {
        ReaderYouTubeStage(videoID: videoID, title: title, autoplay: autoplay, thumbnail: thumbnail,
                           durationSec: durationSec, vertical: vertical, resumeAt: resumeAt, controller: controller)
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
    let controller: ReaderYouTubeController

    @State private var started: Bool
    /// Where the player starts: 0, where it was left last time, or a transcript line clicked before it was loaded.
    @State private var startTime: Double
    /// The poster is gone: playback started, or the player failed or took too long and is shown as is.
    @State private var revealed = false
    /// The video's SponsorBlock segments in every category, fetched once the player is created; what the page
    /// gets is these under the settings (`segmentsJSON`).
    @State private var segments: [SponsorBlockSegment] = []
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @State private var fullscreen: ReaderYouTubeFullscreenStart?
    #endif

    init(videoID: String, title: String, autoplay: Bool, thumbnail: String?, durationSec: Int?, vertical: Bool,
         resumeAt: Double?, controller: ReaderYouTubeController) {
        self.videoID = videoID
        self.title = title
        self.thumbnail = thumbnail
        self.durationSec = durationSec
        self.vertical = vertical
        self.controller = controller
        _started = State(initialValue: autoplay)
        _startTime = State(initialValue: resumeAt ?? 0)
    }

    /// The player page's segment list (`window.odPlayer.setSegments`): empty with SponsorBlock off.
    private var segmentsJSON: String {
        guard model.settings.sponsorBlock else { return "[]" }
        return SponsorBlock.playerJSON(SponsorBlock.playerSegments(segments, mode: model.settings.sponsorBlockMode))
    }

    var body: some View {
        ZStack {
            if started {
                ReaderYouTubeRepresentable(videoID: videoID, title: title, start: Int(startTime), inCover: false,
                                           segmentsJSON: segmentsJSON, controller: controller, onEvent: handle)
            }
            if !revealed {
                ReaderYouTubePoster(videoID: videoID, title: title, thumbnail: thumbnail, durationSec: durationSec,
                                    vertical: vertical, loading: started) { started = true }
                    .transition(.opacity)
            }
        }
        .onAppear {
            controller.time = 0
            controller.start = { time in
                startTime = time
                started = true
            }
            ReaderYouTubeController.current = controller
        }
        .onDisappear {
            if ReaderYouTubeController.current === controller { ReaderYouTubeController.current = nil }
        }
        .task(id: started && model.settings.sponsorBlock) {
            guard started, model.settings.sponsorBlock else { return }
            segments = await model.services.sponsorBlock.segments(forVideoID: videoID)
        }
        .task(id: started) {
            // Autoplay refused or a slow network: hand over to the player (and its play button) after a while.
            guard started, !revealed, (try? await Task.sleep(for: .seconds(8))) != nil else { return }
            reveal()
        }
        #if os(iOS)
        .fullScreenCover(item: $fullscreen) { start in
            ReaderYouTubeFullscreen(videoID: videoID, title: title, start: start.time, vertical: vertical,
                                    segmentsJSON: segmentsJSON) { time in
                fullscreen = nil
                controller.inFullscreen = false
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
        case .fullscreen(let time):
            controller.inFullscreen = true
            fullscreen = ReaderYouTubeFullscreenStart(time: time)
        #else
        case .fullscreen: break
        #endif
        case .exitFullscreen: break
        case .time(let time, let duration):
            if duration > 0 { controller.duration = duration }
            controller.time = time
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
    /// The reader's segment list, so the cover's player skips like the one under it.
    let segmentsJSON: String
    let onExit: (Double) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ReaderYouTubeRepresentable(videoID: videoID, title: title, start: Int(start), inCover: true, segmentsJSON: segmentsJSON,
                                       controller: nil) { event in
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
    /// Seconds in, and the video's length once the player knows it (else 0).
    case time(Double, Double)
}

/// Lets the stage reach the player's page (resume after the iPhone full-screen cover closes), the
/// window's key monitor reach the reader's player (Space plays or pauses it and ←/→ skip wherever focus
/// is), and the transcript follow and seek the video.
@MainActor
@Observable
final class ReaderYouTubeController {
    /// The player in the reader, if it shows a video (the most recent one, with several panes).
    static weak var current: ReaderYouTubeController?

    /// Seconds into the video, updated as playback crosses each second.
    var time: Double = 0
    /// The video's length as the player reports it with the time; 0 until it knows.
    @ObservationIgnored var duration: Double = 0
    @ObservationIgnored weak var webView: WKWebView?
    /// Presses the poster's play button (before the player is loaded), starting at the given second.
    @ObservationIgnored var start: ((Double) -> Void)?
    /// The iPhone's full-screen player is up: the reader under it disappears but keeps its player.
    @ObservationIgnored var inFullscreen = false

    func togglePlayback() {
        if let webView {
            webView.evaluateJavaScript("window.odPlayer && window.odPlayer.toggle()")
        } else {
            start?(0)
        }
    }

    /// Plays from `time`: seeks the player, or loads it starting there.
    func play(from time: Double) {
        if webView != nil { resume(at: time) } else { start?(time) }
    }

    /// Skips by `seconds` (negative goes back). Nothing before the player is loaded.
    func seek(by seconds: Double) {
        webView?.evaluateJavaScript("window.odPlayer && window.odPlayer.seekBy(\(seconds))")
    }

    func resume(at time: Double) {
        webView?.evaluateJavaScript("window.odPlayer && window.odPlayer.resume(\(time))")
    }

    /// The reader left this video: blank the player. The lazy stack that pins the theater player doesn't
    /// always dismantle its web view, which then played on out of sight.
    func stop() {
        guard !inFullscreen, let webView else { return }
        webView.loadHTMLString("", baseURL: nil)
        self.webView = nil
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
    /// The segment list last handed to the page, replayed when a load finishes: the first push can reach the
    /// page before it exists, and a reload starts with none.
    private var segmentsJSON: String?
    var onEvent: (ReaderYouTubeEvent) -> Void = { _ in }
    #if os(iOS)
    /// The page's last `state` message: the video is playing.
    private var playing = false
    /// It was playing as the app stopped being active, so it plays again once iOS has paused it in the background.
    private var playingAtResign = false
    private weak var webView: WKWebView?
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ReaderWebSupport.policy(for: navigationAction, documentURL: ReaderYouTube.pageOrigin))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushSegments(to: webView)
    }

    func setSegments(_ json: String, on webView: WKWebView) {
        guard json != segmentsJSON else { return }
        segmentsJSON = json
        pushSegments(to: webView)
    }

    /// The page may not have defined `odPlayer` yet; it picks `odPendingSegments` up when it starts.
    private func pushSegments(to webView: WKWebView) {
        guard let json = segmentsJSON else { return }
        webView.evaluateJavaScript("window.odPlayer ? window.odPlayer.setSegments(\(json)) : (window.odPendingSegments = \(json))")
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
        case "time": onEvent(.time(time, (body["duration"] as? NSNumber)?.doubleValue ?? 0))
        case "state": stateChanged(playing: body["playing"] as? Bool ?? false)
        default: break
        }
    }

    private func stateChanged(playing: Bool) {
        #if os(iOS)
        self.playing = playing
        if playing {
            // .playback keeps the sound going with the silent switch on and, with UIBackgroundModes audio, locked.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
        #endif
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
        self.webView = webView
        observeLifecycle()
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
        #if os(iOS)
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        #endif
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ReaderYouTubePage.handlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    #if os(iOS)
    /// WebKit pauses a video with sound when the app goes to the background or the phone locks, unlike the
    /// podcast player's AVPlayer. A video that was playing is told to play again a moment later, which WebKit
    /// allows with the app's background audio mode, so the sound carries on with the screen off.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.playingAtResign = self.playing } }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeInBackground() }
        })
    }

    private func resumeInBackground() {
        guard playingAtResign, let webView else { return }
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "Resume video", expirationHandler: nil)
        Task { @MainActor [weak webView] in
            // WebKit's pause can land after this notification, so ask more than once.
            for delay in [0.3, 0.7, 1.0, 2.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard app.applicationState == .background, let webView else { break }
                webView.evaluateJavaScript("window.odPlayer && window.odPlayer.play(); void 0", completionHandler: nil)
            }
            app.endBackgroundTask(task)
        }
    }
    #endif
}

#if os(macOS)
private struct ReaderYouTubeRepresentable: NSViewRepresentable {
    let videoID: String
    let title: String
    let start: Int
    let inCover: Bool
    let segmentsJSON: String
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
        context.coordinator.setSegments(segmentsJSON, on: view)
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
    let segmentsJSON: String
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
        context.coordinator.setSegments(segmentsJSON, on: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: ReaderYouTubeCoordinator) {
        coordinator.dismantle(view)
    }
}
#endif
