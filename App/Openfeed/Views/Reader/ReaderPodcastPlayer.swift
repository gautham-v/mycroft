import AVFoundation
import MediaPlayer
import OpenfeedCore
import os
import SwiftUI

/// Native audio player with the episode art beside it (port of PodcastPlayer in reader.tsx).
/// Never autoplays; resumes where you left off (UserDefaults "openfeed:podcast-pos:<id>", saved every
/// 5 s, on pause and when the reader moves on; cleared when the episode ends). Like the web app's
/// <audio> element, playback belongs to the reader: switching items or closing the reader stops it
/// (after saving the position). While it plays it owns Now Playing and the remote commands (lock
/// screen, Control Center, headphone and media keys), and on iOS it keeps going in the background and
/// with the silent switch on (audio session category .playback, UIBackgroundModes audio).
struct ReaderPodcastPlayer: View {
    let item: FeedItem
    let art: String?
    let wide: Bool

    @State private var player: ReaderPodcastPlayback

    init(item: FeedItem, art: String?, wide: Bool) {
        self.item = item
        self.art = art
        self.wide = wide
        _player = State(initialValue: ReaderPodcastPlayback(itemID: item.id, audioURL: item.item.audioUrl,
                                                            knownDuration: item.item.durationSec))
    }

    var body: some View {
        HStack(spacing: 14) {
            if let art, let url = URL(string: art) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.ofCode
                    }
                }
                .frame(width: wide ? 72 : 64, height: wide ? 72 : 64)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            }
            controls
        }
        .padding(12)
        .background(Color.ofGround, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ofHairline))
        .onAppear { player.setNowPlayingInfo(title: item.item.title, show: item.source.title, art: art) }
        .onChange(of: art) { _, art in player.setNowPlayingInfo(title: item.item.title, show: item.source.title, art: art) }
        .onDisappear { player.teardown() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 17))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")

                Button { player.togglePlay() } label: {
                    ZStack {
                        Circle().fill(Color.ofAccent)
                        if player.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                #if os(macOS)
                                .colorScheme(.dark)
                                #endif
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                }
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause \(item.item.title)" : "Play \(item.item.title)")
                .accessibilityIdentifier("podcast-play")

                Button { player.skip(by: 30) } label: {
                    Image(systemName: "goforward.30").font(.system(size: 17))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .help("Forward 30 seconds")
                .accessibilityLabel("Forward 30 seconds")

                Spacer(minLength: 4)

                Menu {
                    ForEach(ReaderPodcastPlayback.rates, id: \.self) { rate in
                        Button {
                            player.rate = rate
                        } label: {
                            if rate == player.rate {
                                Label(ReaderPodcastPlayback.rateLabel(rate), systemImage: OFIcon.check.rawValue)
                            } else {
                                Text(ReaderPodcastPlayback.rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(ReaderPodcastPlayback.rateLabel(player.rate))
                        .font(OFFont.ui(12.5, .medium).monospacedDigit())
                        .foregroundStyle(.ofInk)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofHairline))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Playback speed")
                .accessibilityLabel("Playback speed \(ReaderPodcastPlayback.rateLabel(player.rate))")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.ofInk)

            Slider(value: Binding(get: { player.displayTime },
                                  set: { player.scrub(to: $0) }),
                   in: 0...max(player.duration, 1),
                   onEditingChanged: { editing in player.setScrubbing(editing) })
                .controlSize(.small)
                .tint(.ofAccent)
                .disabled(player.duration <= 0)
                .accessibilityLabel("Position")
                .accessibilityValue(ReaderPodcastPlayback.clock(player.displayTime))

            HStack {
                Text(ReaderPodcastPlayback.clock(player.displayTime))
                Spacer()
                Text(player.duration > 0 ? "-" + ReaderPodcastPlayback.clock(max(player.duration - player.displayTime, 0)) : "--:--")
            }
            .font(OFFont.ui(11.5).monospacedDigit())
            .foregroundStyle(.ofMuted)

            if let error = player.errorMessage {
                Text(error).font(OFFont.ui(12)).foregroundStyle(.ofDanger)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// AVPlayer wrapper. The player item is created on the first Play (like preload="none").
@MainActor @Observable
final class ReaderPodcastPlayback {
    static let rates: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2]
    static let saveEvery: TimeInterval = 5
    nonisolated static let log = Logger(subsystem: "com.gauthamv.openfeed", category: "podcast")

    let itemID: Int64
    let audioURL: URL?
    /// Playing or about to (AVPlayer is playing or waiting to play), so the button shows Pause.
    private(set) var isPlaying = false
    /// Waiting for data before it can play.
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var errorMessage: String?
    private var scrubTime: Double?
    var rate: Float = 1 {
        didSet {
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
            updateNowPlaying()
        }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var nowPlaying = NowPlayingMeta()

    init(itemID: Int64, audioURL: String?, knownDuration: Int?) {
        self.itemID = itemID
        self.audioURL = audioURL.flatMap { URL(string: $0) }
        duration = Double(knownDuration ?? 0)
        let saved = Self.savedPosition(itemID)
        if saved > 0 && (duration <= 0 || saved < duration - 5) { currentTime = saved }
    }

    var displayTime: Double { scrubTime ?? currentTime }

    static func positionKey(_ id: Int64) -> String { "openfeed:podcast-pos:\(id)" }
    static func savedPosition(_ id: Int64) -> Double { UserDefaults.standard.double(forKey: positionKey(id)) }

    static func rateLabel(_ rate: Float) -> String {
        let s = rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%g", rate)
        return s + "x"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return TextFormat.duration(Int(seconds)) ?? "0:00"
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let audioURL else {
            errorMessage = "No audio for this episode"
            return
        }
        errorMessage = nil
        #if os(iOS)
        // .playback keeps playing with the silent switch on and, with UIBackgroundModes audio, in the background.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            Self.log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        if let item = player?.currentItem, item.status == .failed { releasePlayer() }
        if player == nil { makePlayer(audioURL) }
        PodcastRemote.activate(self)
        player?.playImmediately(atRate: rate)
        isPlaying = true
        Self.log.notice("play item=\(self.itemID) at=\(self.currentTime) rate=\(self.rate)")
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        isBuffering = false
        resumeAfterInterruption = false
        savePosition()
        Self.log.notice("pause item=\(self.itemID) at=\(self.currentTime)")
        updateNowPlaying()
    }

    func skip(by delta: Double) {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        seek(to: min(max(currentTime + delta, 0), upper))
    }

    func setScrubbing(_ editing: Bool) {
        if editing {
            scrubTime = currentTime
        } else if let t = scrubTime {
            scrubTime = nil
            seek(to: t)
        }
    }

    func scrub(to t: Double) {
        if scrubTime != nil { scrubTime = t } else { seek(to: t) }
    }

    func seek(to t: Double) {
        currentTime = t
        if let player {
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        savePosition()
        updateNowPlaying()
    }

    /// Saves the position and releases the player (reader closed or switched items).
    func teardown() {
        savePosition()
        let hadPlayer = player != nil
        releasePlayer()
        isPlaying = false
        isBuffering = false
        PodcastRemote.deactivate(self)
        if hadPlayer { Self.log.notice("teardown item=\(self.itemID) at=\(self.currentTime)") }
    }

    // MARK: Now Playing

    struct NowPlayingMeta {
        var title = ""
        var show = ""
        var art: String?
        var artwork: MPMediaItemArtwork?
    }

    func setNowPlayingInfo(title: String, show: String, art: String?) {
        let artChanged = art != nowPlaying.art
        nowPlaying.title = title
        nowPlaying.show = show
        nowPlaying.art = art
        if artChanged {
            nowPlaying.artwork = nil
            if let art, let url = URL(string: art) {
                Task { [weak self] in
                    guard let artwork = await Self.loadArtwork(url) else { return }
                    guard let self, self.nowPlaying.art == art else { return }
                    self.nowPlaying.artwork = artwork
                    self.updateNowPlaying()
                }
            }
        }
        updateNowPlaying()
    }

    /// Publishes title, show, art, duration, position and rate while this episode owns Now Playing.
    fileprivate func updateNowPlaying() {
        guard PodcastRemote.owner === self else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPMediaItemPropertyArtist: nowPlaying.show,
            MPMediaItemPropertyAlbumTitle: nowPlaying.show,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: displayTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork = nowPlaying.artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// Built outside the main actor: MPMediaItemArtwork calls its request handler on a background queue.
    nonisolated private static func loadArtwork(_ url: URL) async -> MPMediaItemArtwork? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: Player

    private func makePlayer(_ url: URL) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = rate
        self.player = player
        let start = currentTime
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        Self.log.notice("load item=\(self.itemID) url=\(url.absoluteString, privacy: .public) from=\(start)")
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnd() }
        })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            MainActor.assumeIsolated { self?.interrupted(began: began, shouldResume: shouldResume) }
        })
        #endif
        statusObservation = Self.observeStatus(item) { [weak self] failed, message, total in
            self?.statusChanged(failed: failed, message: message, duration: total)
        }
        controlObservation = Self.observeControl(player) { [weak self] status, waitingReason, rate in
            self?.controlChanged(status, waitingReason: waitingReason, rate: rate)
        }
    }

    /// KVO closures are created outside the main actor and hop to it.
    nonisolated private static func observeStatus(
        _ item: AVPlayerItem, _ handler: @escaping @MainActor @Sendable (Bool, String?, Double) -> Void
    ) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            let total = item.duration.seconds
            Task { @MainActor in handler(failed, message, total) }
        }
    }

    nonisolated private static func observeControl(
        _ player: AVPlayer, _ handler: @escaping @MainActor @Sendable (AVPlayer.TimeControlStatus, String?, Float) -> Void
    ) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue
            let rate = player.rate
            Task { @MainActor in handler(status, reason, rate) }
        }
    }

    private func releasePlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        statusObservation = nil
        controlObservation = nil
        player = nil
    }

    private func statusChanged(failed: Bool, message: String?, duration total: Double) {
        if failed {
            isPlaying = false
            isBuffering = false
            errorMessage = message ?? "Could not play this episode"
            Self.log.error("failed item=\(self.itemID): \(message ?? "unknown", privacy: .public)")
            updateNowPlaying()
        } else {
            Self.log.notice("ready item=\(self.itemID) duration=\(total)")
            if total.isFinite, total > 0 { duration = total }
        }
    }

    private func controlChanged(_ status: AVPlayer.TimeControlStatus, waitingReason: String?, rate: Float) {
        guard player != nil else { return }
        let label = switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting(\(waitingReason ?? "-"))"
        case .playing: "playing"
        @unknown default: "unknown"
        }
        Self.log.notice("timeControlStatus=\(label, privacy: .public) rate=\(rate) item=\(self.itemID)")
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        let playing = status != .paused
        if playing != isPlaying {
            isPlaying = playing
            // Paused by the system (route change, interruption, error): keep the spot.
            if !playing { savePosition() }
            updateNowPlaying()
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
            Self.log.notice("interruption began item=\(self.itemID)")
        } else {
            Self.log.notice("interruption ended item=\(self.itemID) resume=\(shouldResume && self.resumeAfterInterruption)")
            if shouldResume && resumeAfterInterruption { play() }
            resumeAfterInterruption = false
        }
    }

    private func tick(_ seconds: Double) {
        guard let player else { return }
        if seconds.isFinite, scrubTime == nil { currentTime = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        if Date().timeIntervalSince(lastSave) >= Self.saveEvery { savePosition() }
    }

    private func didEnd() {
        isPlaying = false
        isBuffering = false
        currentTime = 0
        player?.pause()
        player?.seek(to: .zero)
        UserDefaults.standard.removeObject(forKey: Self.positionKey(itemID))
        lastSave = Date()
        Self.log.notice("ended item=\(self.itemID)")
        updateNowPlaying()
    }

    private func savePosition() {
        lastSave = Date()
        guard currentTime > 0 else { return }
        if duration > 0 && currentTime >= duration - 1 { return }
        UserDefaults.standard.set(floor(currentTime), forKey: Self.positionKey(itemID))
    }
}

/// Remote commands (lock screen, Control Center, headphones, media keys) for the episode that last
/// started playing. Installed once; handlers act on the current owner.
@MainActor
enum PodcastRemote {
    private(set) static weak var owner: ReaderPodcastPlayback?
    private static var installed = false

    static func activate(_ playback: ReaderPodcastPlayback) {
        installIfNeeded()
        if owner !== playback {
            owner?.pause()
            owner = playback
        }
    }

    static func deactivate(_ playback: ReaderPodcastPlayback) {
        guard owner === playback else { return }
        owner = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #else
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget(handler: handler { $0.play() })
        c.pauseCommand.addTarget(handler: handler { $0.pause() })
        c.togglePlayPauseCommand.addTarget(handler: handler { $0.togglePlay() })
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget(handler: handler { $0.skip(by: 30) })
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget(handler: handler { $0.skip(by: -15) })
        c.changePlaybackPositionCommand.addTarget(handler: positionHandler())
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }

    /// Handlers are built outside the main actor (MediaPlayer may call them on any queue) and hop to it.
    nonisolated private static func handler(
        _ action: @escaping @MainActor @Sendable (ReaderPodcastPlayback) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in
                guard let owner = PodcastRemote.owner else { return }
                action(owner)
            }
            return .success
        }
    }

    nonisolated private static func positionHandler() -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = event.positionTime
            Task { @MainActor in PodcastRemote.owner?.seek(to: t) }
            return .success
        }
    }
}
