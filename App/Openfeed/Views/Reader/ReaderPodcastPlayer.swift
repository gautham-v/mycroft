import AVFoundation
import OpenfeedCore
import SwiftUI

/// Native audio player with the episode art beside it (port of PodcastPlayer in reader.tsx).
/// Never autoplays; resumes where you left off (UserDefaults "openfeed:podcast-pos:<id>", saved every
/// 5 s, on pause and when the reader moves on; cleared when the episode ends).
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
        .onDisappear { player.teardown() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 17))
                        .frame(width: 32, height: 32)
                }
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.ofAccent))
                }
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause \(item.item.title)" : "Play \(item.item.title)")

                Button { player.skip(by: 30) } label: {
                    Image(systemName: "goforward.30").font(.system(size: 17))
                        .frame(width: 32, height: 32)
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

    let itemID: Int64
    let audioURL: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var errorMessage: String?
    private var scrubTime: Double?
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastSave = Date.distantPast

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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if player == nil { makePlayer(audioURL) }
        player?.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        savePosition()
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
    }

    /// Saves the position and releases the player (reader closed or switched items).
    func teardown() {
        savePosition()
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player = nil
    }

    private func makePlayer(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        let start = currentTime
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnd() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            let total = item.duration.seconds
            Task { @MainActor in self?.statusChanged(failed: failed, message: message, duration: total) }
        }
    }

    private func statusChanged(failed: Bool, message: String?, duration total: Double) {
        if failed {
            isPlaying = false
            errorMessage = message ?? "Could not play this episode"
        } else if total.isFinite, total > 0 {
            duration = total
        }
    }

    private func tick(_ seconds: Double) {
        guard let player else { return }
        if seconds.isFinite, scrubTime == nil { currentTime = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying { isPlaying = playing }
        if Date().timeIntervalSince(lastSave) >= Self.saveEvery { savePosition() }
    }

    private func didEnd() {
        isPlaying = false
        currentTime = 0
        player?.seek(to: .zero)
        UserDefaults.standard.removeObject(forKey: Self.positionKey(itemID))
        lastSave = Date()
    }

    private func savePosition() {
        lastSave = Date()
        guard currentTime > 0 else { return }
        if duration > 0 && currentTime >= duration - 1 { return }
        UserDefaults.standard.set(floor(currentTime), forKey: Self.positionKey(itemID))
    }
}
