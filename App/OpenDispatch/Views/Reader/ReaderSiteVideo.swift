import AVKit
import OpenDispatchCore
import SwiftUI

/// The player for a page whose video the site's own player loads (`SiteVideo`, NFL.com's /videos/ pages): the poster
/// with a play button until it is pressed, then `SiteVideoResolver` finds the stream in a hidden web view (a spinner
/// meanwhile) and AVKit plays it. The stream is signed for a short time, so it is found again on every play, never
/// cached. When none turns up the poster says so and offers the page.
struct ReaderSiteVideo: View {
    let page: URL
    let poster: String?
    let title: String

    private enum Phase: Equatable { case idle, resolving, playing, failed }

    @State private var phase: Phase = .idle
    @State private var player: AVPlayer?
    @State private var hovering = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if phase == .playing, let player {
                #if os(iOS)
                ReaderBackgroundVideoPlayer(player: player)
                #else
                VideoPlayer(player: player)
                #endif
            } else {
                posterButton
            }
        }
        .overlay(alignment: .bottom) {
            if phase == .failed { failure }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDisappear {
            player?.pause()
            player = nil
            phase = .idle
        }
    }

    private func play() {
        guard phase == .idle || phase == .failed else { return }
        phase = .resolving
        Task { @MainActor in
            guard let stream = await SiteVideoResolver.stream(for: page) else {
                if phase == .resolving { phase = .failed }
                return
            }
            guard phase == .resolving else { return }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let player = AVPlayer(url: stream)
            self.player = player
            phase = .playing
            player.play()
        }
    }

    private var posterButton: some View {
        Button { play() } label: {
            Color.black
                .overlay {
                    CachedAsyncImage(url: poster.flatMap(URL.init(string:)), maxPixelSize: 1600) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { _ in
                        Color.black
                    }
                }
                .overlay { button }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(phase == .resolving ? "Loading \(title)" : "Play \(title)")
    }

    private var button: some View {
        Circle()
            .fill(Color.black.opacity(hovering && phase != .resolving ? 0.6 : 0.42))
            .background(.ultraThinMaterial, in: Circle())
            .frame(width: 64, height: 64)
            .overlay {
                if phase == .resolving {
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

    private var failure: some View {
        HStack(spacing: 10) {
            Text("The video didn't load here.")
            Button { openURL(page) } label: {
                HStack(spacing: 4) {
                    Text("Watch on \(ReaderSiteVideo.siteName(page))")
                    OFIcon.external.image.font(.system(size: 11))
                }
                .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
        }
        .font(OFFont.ui(12.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(12)
    }

    static func siteName(_ url: URL) -> String {
        let host = url.host() ?? "the site"
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

#if os(iOS)
/// AVKit's player, let go of while the app is in the background: iOS pauses a player whose video is on screen when
/// the app leaves the foreground or the phone locks, and one with no view keeps playing its sound (the session is
/// .playback and the app has UIBackgroundModes audio). The view gets it back on return. Not while it is in
/// Picture in Picture, which plays on by itself.
private struct ReaderBackgroundVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.player = player
        if !context.coordinator.detached, controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var controller: AVPlayerViewController?
        var player: AVPlayer?
        private(set) var detached = false
        private var inPictureInPicture = false
        private var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattach() }
            })
        }

        private func detach() {
            guard !inPictureInPicture, let controller, let player, player.timeControlStatus != .paused else { return }
            controller.player = nil
            detached = true
        }

        private func reattach() {
            guard detached else { return }
            detached = false
            controller?.player = player
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated { inPictureInPicture = true }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated { inPictureInPicture = false }
        }
    }
}
#endif
