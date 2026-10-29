import AVFoundation
import FluidAudio
import os

/// The natural voice for Read aloud: Kokoro-82M's "Heart" (af_heart) running on device through Core ML
/// (FluidAudio's `KokoroAneManager`). English only. The models (about 90 MB) download from Hugging Face
/// the first time it speaks and stay in Application Support; nothing is sent anywhere after that.
@MainActor @Observable
final class NaturalVoice {
    /// `downloading` the first time (no models on this device yet), `loading` from disk after that.
    enum Phase { case notLoaded, downloading, loading, ready, failed }

    /// `AppSettings.speechVoice` for this voice.
    nonisolated static let voiceID = "kokoro.af_heart"
    nonisolated static let name = "Heart"
    private nonisolated static let kokoroVoice = "af_heart"
    nonisolated static let sampleRate: Double = 24_000

    private(set) var phase: Phase = .notLoaded

    @ObservationIgnored private var manager: KokoroAneManager?
    @ObservationIgnored private var loading: Task<KokoroAneManager, any Error>?

    /// Where the models live: Application Support (in the sandbox container on the Mac), not Caches,
    /// which the system may empty.
    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "NaturalVoice", directoryHint: .isDirectory)
    }

    /// The loaded model, downloading and compiling it the first time. Concurrent callers share one load;
    /// a failed one is retried by the next call.
    func load() async throws -> KokoroAneManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        phase = FileManager.default.fileExists(atPath: Self.directory.path(percentEncoded: false)) ? .loading : .downloading
        let task = Task<KokoroAneManager, any Error> {
            let manager = KokoroAneManager(directory: Self.directory)
            try await manager.initialize(preloadVoices: [Self.kokoroVoice])
            return manager
        }
        loading = task
        let began = Date()
        do {
            let loaded = try await task.value
            ReaderSpeech.log.notice("natural voice loaded in \(Date().timeIntervalSince(began), format: .fixed(precision: 1))s")
            manager = loaded
            phase = .ready
            loading = nil
            return loaded
        } catch {
            ReaderSpeech.log.error("natural voice: load: \(String(describing: error), privacy: .public)")
            phase = .failed
            loading = nil
            throw error
        }
    }

    /// One sentence as 24 kHz mono samples, then `pause` seconds of silence. `speed` is the player's
    /// multiplier, which Kokoro applies itself (it paces the speech rather than stretching audio).
    func synthesize(_ text: String, speed: Float, pause: Double) async throws -> AVAudioPCMBuffer {
        let manager = try await load()
        let result = try await manager.synthesizeDetailed(text: text, voice: Self.kokoroVoice, speed: speed)
        let silence = Int(pause * Self.sampleRate)
        let frames = result.samples.count + silence
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let channel = buffer.floatChannelData?[0] else {
            throw NaturalVoiceError.noBuffer
        }
        result.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { channel.update(from: base, count: samples.count) }
        }
        (channel + result.samples.count).initialize(repeating: 0, count: silence)
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

enum NaturalVoiceError: Error { case noBuffer }

/// Plays sentences in the natural voice: synthesizes them in order ahead of playback and queues each
/// on an AVAudioEngine player node, so one follows the next without a gap. Reports, by sentence index,
/// when one starts and finishes and how far into it playback is; `ReaderSpeech` drives the rest
/// (highlight, times, Now Playing) as it does for the system voice.
///
/// Synthesis runs up to five minutes ahead. On iOS the Neural Engine is not available to an app in the
/// background, so a long lookahead keeps a locked phone reading; if a sentence can't be made at all,
/// `onFailure` hands it (once what is queued has played) back to `ReaderSpeech`, which carries on with
/// the system voice.
@MainActor
final class NaturalSpeechPlayer {
    struct Line {
        var text: String
        /// Silence after it, seconds.
        var pause: Double
    }

    var onStart: (Int) -> Void = { _ in }
    var onFinish: (Int) -> Void = { _ in }
    /// Sentence index and how much of it has played, 0 to 1.
    var onProgress: (Int, Double) -> Void = { _, _ in }
    var onFailure: (Int) -> Void = { _ in }
    /// The audio route or device changed and the engine stopped; the caller restarts the sentence.
    var onReset: () -> Void = {}

    private static let lookahead: Double = 300

    private let voice: NaturalVoice
    private let lines: [Line]
    private let first: Int
    private let speed: Float
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var synthesis: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Queued sentences that haven't finished playing, in order, with their lengths in seconds.
    private var queued: [(index: Int, seconds: Double)] = []
    private var failedAt: Int?
    private var paused = false
    private var stopped = false
    /// Playing time of the current sentence before the last resume, and when that resume was.
    private var playedBefore: Double = 0
    private var playingSince: Date?
    private var observer: (any NSObjectProtocol)?

    init(voice: NaturalVoice, lines: [Line], from first: Int, speed: Float) {
        self.voice = voice
        self.lines = lines
        self.first = first
        self.speed = speed
        let format = AVAudioFormat(standardFormatWithSampleRate: NaturalVoice.sampleRate, channels: 1)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                ReaderSpeech.log.notice("natural voice: audio configuration changed")
                self.onReset()
            }
        }
        startEngine()
        synthesis = Task { [weak self] in await self?.synthesizeAll() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        node.pause()
        if let since = playingSince { playedBefore += Date().timeIntervalSince(since) }
        playingSince = nil
    }

    /// Plays on after `pause`; false when the engine stopped meanwhile (an interruption), which drops
    /// what was queued, so the caller starts the sentence again.
    func resume() -> Bool {
        guard paused else { return true }
        guard engine.isRunning else { return false }
        paused = false
        node.play()
        if !queued.isEmpty { playingSince = Date() }
        return true
    }

    func stop() {
        stopped = true
        synthesis?.cancel()
        ticker?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        node.stop()
        engine.stop()
        queued = []
    }

    private func startEngine() {
        do {
            if !engine.isRunning { try engine.start() }
            if !paused { node.play() }
        } catch {
            ReaderSpeech.log.error("natural voice: engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func synthesizeAll() async {
        var index = first
        while index < lines.count, !Task.isCancelled {
            while queued.reduce(0, { $0 + $1.seconds }) > Self.lookahead {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            let line = lines[index]
            do {
                let began = Date()
                let buffer = try await voice.synthesize(line.text, speed: speed, pause: line.pause)
                guard !Task.isCancelled, !stopped else { return }
                let seconds = Double(buffer.frameLength) / NaturalVoice.sampleRate
                ReaderSpeech.log.debug("natural voice: sentence \(index), \(seconds, format: .fixed(precision: 1))s in \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s")
                enqueue(buffer, index: index)
            } catch {
                guard !Task.isCancelled, !stopped else { return }
                ReaderSpeech.log.error("natural voice: sentence \(index): \(String(describing: error), privacy: .public)")
                failedAt = index
                if queued.isEmpty { onFailure(index) }
                return
            }
            index += 1
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, index: Int) {
        queued.append((index, Double(buffer.frameLength) / NaturalVoice.sampleRate))
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(index) }
        }
        if queued.count == 1 { started(index) }
    }

    private func started(_ index: Int) {
        playedBefore = 0
        playingSince = paused ? nil : Date()
        onStart(index)
    }

    private func finished(_ index: Int) {
        guard !stopped, queued.first?.index == index else { return }
        queued.removeFirst()
        playingSince = nil
        onFinish(index)
        guard !stopped else { return }
        if let next = queued.first {
            started(next.index)
        } else if let failedAt {
            onFailure(failedAt)
        }
    }

    private func tick() {
        guard !stopped, let current = queued.first, current.seconds > 0 else { return }
        var played = playedBefore
        if let since = playingSince { played += Date().timeIntervalSince(since) }
        onProgress(current.index, min(played / current.seconds, 1))
    }
}
