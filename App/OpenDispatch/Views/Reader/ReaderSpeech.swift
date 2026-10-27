import AVFoundation
import MediaPlayer
import OpenDispatchCore
import os
import SwiftUI

extension Notification.Name {
    /// The podcast player started playing: Read aloud gives way (and the other way round, see `ReaderSpeech.begin`).
    static let readerPodcastDidStart = Notification.Name("openfeed.reader.podcast-did-start")
}

/// Read aloud (Listen in the reader): speaks the headline, then the article sentence by sentence with
/// AVSpeechSynthesizer, highlighting the one being spoken in the article and scrolling to keep it in
/// view (`ReaderSpeechPage`). One session at a time, app-wide, in whichever reader pane started it;
/// the player bar (`ReaderSpeechBar`) and the toolbar's Listen button read its state.
///
/// Like the podcast player, playback belongs to the reader: leaving the article (another item or tab,
/// back to the list, split view or the article reloading) stops it. While it speaks it owns Now Playing
/// and the remote commands (previous / next track step a sentence), and on iOS it keeps going in the
/// background and with the silent switch on (audio session .playback, mode .spokenAudio). Starting it
/// pauses the podcast and the podcast starting pauses it.
@MainActor @Observable
final class ReaderSpeech {
    enum State { case idle, playing, paused }
    enum Start { case beginning, selection }

    // Subsystem is the bundle id (which keeps the app's original name).
    nonisolated static let log = Logger(subsystem: "com.gauthamv.openfeed", category: "speech")

    private(set) var state: State = .idle
    /// The article being read and where it is from, for the bar and Now Playing.
    private(set) var title = ""
    private(set) var source = ""
    /// The entry being spoken (the headline is entry 0), and how many there are.
    private(set) var current = 0
    private(set) var count = 0
    /// Seconds into the article and its total, both estimated (see `estimates`).
    private(set) var elapsed: Double = 0
    private(set) var total: Double = 0
    private(set) var rate: Float = 1
    /// Which article view is being read (`ReaderSpeechPage`).
    private(set) var owner: ObjectIdentifier?
    /// Bumped by the Listen menu command; the reader pane that has focus answers it.
    private(set) var commandToken = 0

    @ObservationIgnored private weak var page: ReaderSpeechPage?
    @ObservationIgnored private var entries: [Entry] = []
    /// Entries before the first article sentence: 1 with a headline, else 0.
    @ObservationIgnored private var leadCount = 0
    @ObservationIgnored private var voiceID: String?
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var delegate: SynthesizerDelegate?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: [ObjectIdentifier: Queued] = [:]
    @ObservationIgnored private var nextToQueue = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var presentTask: Task<Void, Never>?
    /// Spoken part of the current sentence, 0 to 1.
    @ObservationIgnored private var progress: Double = 0
    /// The speed or voice changed while paused: resume from the sentence's start, not mid-word.
    @ObservationIgnored private var restartOnResume = false
    @ObservationIgnored private var interruptedWhilePlaying = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var estimates = Estimates()
    @ObservationIgnored private var sentenceStartedAt: Date?
    @ObservationIgnored private var sentencePaused = false
    @ObservationIgnored private var previewSynthesizer: AVSpeechSynthesizer?

    private struct Entry {
        var text: String
        var endsBlock: Bool
        var words: Int
    }

    private struct Queued {
        var generation: Int
        var index: Int
    }

    func owns(_ page: ReaderSpeechPage) -> Bool { state != .idle && owner == ObjectIdentifier(page) }
    var isActive: Bool { state != .idle }

    // MARK: Starting and stopping

    /// Listen button / menu command: starts reading the article (from the beginning, or from the
    /// selection), or pauses and resumes it when this page is already being read.
    func toggle(page: ReaderSpeechPage, item: FeedItem, settings: AppSettings, from start: Start = .beginning) {
        if owns(page) {
            if start == .selection {
                Task { if let index = await page.selectionIndex(), owns(page) { jump(to: leadCount + index) } }
            } else {
                togglePlayPause()
            }
            return
        }
        guard page.isReady else { return }
        stop()
        owner = ObjectIdentifier(page)
        self.page = page
        let isPost = TextFormat.isSocialPost(item.item.url)
        title = item.item.title
        source = item.source.title
        voiceID = settings.speechVoice
        rate = settings.speechRate
        page.onJump = { [weak self, weak page] index in
            guard let self, let page, self.owns(page) else { return }
            self.jump(to: self.leadCount + index)
        }
        page.onInvalidate = { [weak self, weak page] in
            guard let self, let page else { return }
            self.stop(ifOwnedBy: page)
        }
        startTask = Task { [weak self] in
            await self?.prepare(page: page, headline: isPost ? nil : item.item.title, start: start)
        }
    }

    /// Asks the focused reader pane to start or pause (Listen in the View menu).
    func requestToggle() { commandToken &+= 1 }

    /// Reads the article's sentences, then begins. The session is this page's from the start, but shows
    /// (state is not idle) only once there is something to say.
    private func prepare(page: ReaderSpeechPage, headline: String?, start: Start) async {
        let mine = ObjectIdentifier(page)
        let sample = await page.sampleText()
        let language = ReaderSpeechVoices.language(of: (headline ?? "") + "\n" + sample)
        let sentences = await page.extract(title: headline, language: language)
        guard !Task.isCancelled, owner == mine else { return }
        var built: [Entry] = []
        if let headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            built.append(Entry(text: headline, endsBlock: true, words: Self.words(in: headline)))
        }
        leadCount = built.count
        built += sentences.map { Entry(text: $0.text, endsBlock: $0.endsBlock, words: Self.words(in: $0.text)) }
        guard !built.isEmpty else { stop(); return }
        entries = built
        count = built.count
        voice = ReaderSpeechVoices.resolve(saved: voiceID, language: language)
        estimates = Estimates()
        var first = 0
        if start == .selection, let index = await page.selectionIndex() { first = leadCount + index }
        guard !Task.isCancelled, owner == mine else { return }
        begin(page: page)
        play(from: first)
    }

    /// Takes over audio: the session, Now Playing, the remote commands; pauses the podcast.
    private func begin(page: ReaderSpeechPage) {
        ReaderSpeechRemote.activate(self)
        claimAudio()
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.interrupted(began: began, shouldResume: options.contains(.shouldResume)) }
        })
        // Headphones unplugged: stop talking out loud, like the podcast player does.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .oldDeviceUnavailable { MainActor.assumeIsolated { self?.pause() } }
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: .readerPodcastDidStart, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                ReaderSpeechRemote.ownsNowPlaying = false
                self?.pause()
            }
        })
        page.setActive(true)
        if let web = page.webView { page.scroller.attach(to: web) }
    }

    /// Audio is ours: the podcast pauses, Now Playing shows this session, the audio session is active.
    private func claimAudio() {
        PodcastRemote.owner?.pause()
        ReaderSpeechRemote.ownsNowPlaying = true
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            Self.log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Ends the session: stops speaking, drops the highlight, gives audio back.
    func stop() {
        startTask?.cancel()
        startTask = nil
        presentTask?.cancel()
        presentTask = nil
        generation += 1
        queued = [:]
        silence()
        state = .idle
        owner = nil
        entries = []
        count = 0
        current = 0
        elapsed = 0
        total = 0
        progress = 0
        restartOnResume = false
        interruptedWhilePlaying = false
        if let page {
            page.setActive(false)
            page.scroller.detach()
            page.onJump = nil
            page.onInvalidate = nil
        }
        page = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        ReaderSpeechRemote.deactivate(self)
    }

    /// The reader leaves the article (or it reloads): ends the session if it is this page's.
    func stop(ifOwnedBy page: ReaderSpeechPage) {
        if owner == ObjectIdentifier(page) { stop() }
    }

    private func silence() {
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        delegate = nil
    }

    // MARK: Transport

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer?.pauseSpeaking(at: .immediate)
        state = .paused
        sentencePaused = true
        interruptedWhilePlaying = false
        Self.log.notice("pause entry=\(self.current)")
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        claimAudio()
        page?.scroller.following = true
        if restartOnResume {
            play(from: current)
        } else {
            synthesizer?.continueSpeaking()
            state = .playing
            if let page, let dom = domIndex(current) { reveal(dom, in: page) } else { page?.scroller.scrollToTop() }
            updateNowPlaying()
        }
    }

    func next() { jump(to: current + 1) }
    func previous() { jump(to: current - 1) }

    /// Speaks from entry `index` (past the last ends the session); also wakes a paused session.
    func jump(to index: Int) {
        guard state != .idle else { return }
        if index >= entries.count { stop(); return }
        page?.scroller.following = true
        play(from: max(index, 0))
    }

    func setRate(_ newRate: Float) {
        guard newRate != rate else { return }
        rate = newRate
        estimates.reset()
        switch state {
        case .playing: play(from: current)
        case .paused: restartOnResume = true
        case .idle: break
        }
        updateNowPlaying()
    }

    // MARK: Speaking

    /// (Re)starts speaking at `index`. A fresh synthesizer each time: stopping and restarting one that is
    /// paused or mid-queue leaves it in odd states.
    private func play(from index: Int) {
        generation += 1
        silence()
        queued = [:]
        claimAudio()
        let synth = AVSpeechSynthesizer()
        let delegate = SynthesizerDelegate(owner: self)
        synth.delegate = delegate
        #if os(iOS)
        // Play through the app's own audio session (.playback, spokenAudio, set up in claimAudio).
        synth.usesApplicationAudioSession = true
        #endif
        synthesizer = synth
        self.delegate = delegate
        state = .playing
        restartOnResume = false
        sentencePaused = false
        nextToQueue = index
        present(index)
        fill()
    }

    /// Keeps the current and the next sentence queued, so there is no gap between them.
    private func fill() {
        while queued.count < 2, nextToQueue < entries.count {
            let index = nextToQueue
            let entry = entries[index]
            let utterance = AVSpeechUtterance(string: entry.text)
            utterance.voice = voice
            utterance.rate = ReaderSpeechVoices.utteranceRate(forSpeed: rate)
            utterance.postUtteranceDelay = (entry.endsBlock ? 0.4 : 0.08) / Double(rate)
            queued[ObjectIdentifier(utterance)] = Queued(generation: generation, index: index)
            nextToQueue += 1
            synthesizer?.speak(utterance)
        }
    }

    /// Shows entry `index` as the one being read: highlight, scroll, times, Now Playing.
    private func present(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        current = index
        progress = 0
        updateElapsed()
        updateNowPlaying()
        presentTask?.cancel()
        guard let page else { return }
        if let dom = domIndex(index) {
            reveal(dom, in: page)
        } else {
            presentTask = Task { [weak self] in
                _ = await page.show(nil)
                guard !Task.isCancelled else { return }
                self?.page?.scroller.scrollToTop()
            }
        }
    }

    private func reveal(_ dom: Int, in page: ReaderSpeechPage) {
        presentTask?.cancel()
        presentTask = Task { [weak self] in
            guard let rect = await page.show(dom), !Task.isCancelled else { return }
            self?.page?.scroller.reveal(rect)
        }
    }

    private func domIndex(_ entry: Int) -> Int? { entry >= leadCount ? entry - leadCount : nil }

    // MARK: Synthesizer callbacks

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let q = queued[id], q.generation == generation else { return }
        sentenceStartedAt = Date()
        sentencePaused = false
        if q.index != current { present(q.index) }
        fill()
    }

    fileprivate func didFinish(_ id: ObjectIdentifier) {
        guard let q = queued.removeValue(forKey: id), q.generation == generation else { return }
        if let started = sentenceStartedAt, !sentencePaused, q.index == current {
            estimates.add(words: entries[q.index].words, seconds: Date().timeIntervalSince(started))
        }
        sentenceStartedAt = nil
        if q.index >= entries.count - 1 { stop() } else { fill() }
    }

    fileprivate func didCancel(_ id: ObjectIdentifier) { queued.removeValue(forKey: id) }

    fileprivate func willSpeak(_ id: ObjectIdentifier, range: NSRange) {
        guard let q = queued[id], q.generation == generation, q.index == current else { return }
        let length = max(entries[q.index].text.utf16.count, 1)
        progress = min(Double(range.location + range.length) / Double(length), 1)
        updateElapsed()
    }

    /// The system paused or resumed speech itself (Siri, a call, another app's audio).
    fileprivate func systemPaused() {
        guard state == .playing else { return }
        state = .paused
        interruptedWhilePlaying = true
        updateNowPlaying()
    }
    fileprivate func systemContinued() { if state == .paused, !restartOnResume { state = .playing; updateNowPlaying() } }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            let wasPlaying = state == .playing || interruptedWhilePlaying
            pause()
            interruptedWhilePlaying = wasPlaying
        } else {
            if shouldResume && interruptedWhilePlaying { resume() }
            interruptedWhilePlaying = false
        }
    }

    // MARK: Times

    /// Roughly 2.8 words a second at 1×, which the sentences actually spoken then correct, since voices differ.
    private struct Estimates {
        private var words = 0
        private var seconds: Double = 0
        mutating func add(words w: Int, seconds s: Double) {
            guard w >= 3, s > 0.5 else { return }
            words += w
            seconds += s
        }
        mutating func reset() { words = 0; seconds = 0 }
        func wordsPerSecond(rate: Float) -> Double {
            seconds >= 8 ? Double(words) / seconds : 2.8 * Double(rate)
        }
    }

    private func duration(of entry: Entry, wordsPerSecond: Double) -> Double {
        Double(entry.words) / wordsPerSecond + (entry.endsBlock ? 0.4 : 0.08) / Double(rate)
    }

    private func updateElapsed() {
        let wps = estimates.wordsPerSecond(rate: rate)
        var before = 0.0, all = 0.0
        for (i, entry) in entries.enumerated() {
            let d = duration(of: entry, wordsPerSecond: wps)
            if i < current { before += d }
            if i == current { before += d * progress }
            all += d
        }
        elapsed = before
        total = all
    }

    private static func words(in text: String) -> Int {
        var n = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    // MARK: Now Playing

    /// Publishes the article, position and rate while this session owns Now Playing (lock screen,
    /// Control Center, headphone and media keys).
    fileprivate func updateNowPlaying() {
        guard ReaderSpeechRemote.owner === self, ReaderSpeechRemote.ownsNowPlaying else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: source,
            MPMediaItemPropertyAlbumTitle: source,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: max(total, elapsed),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = state == .playing ? .playing : .paused
        #endif
    }

    // MARK: Settings preview

    /// A few words in a voice, for Settings → Playback. Stops whatever is being read.
    func preview(voice id: String?, speed: Float) {
        stop()
        previewSynthesizer?.stopSpeaking(at: .immediate)
        let synth = AVSpeechSynthesizer()
        previewSynthesizer = synth
        let utterance = AVSpeechUtterance(string: "This is how articles will sound.")
        utterance.voice = ReaderSpeechVoices.resolve(saved: id)
        utterance.rate = ReaderSpeechVoices.utteranceRate(forSpeed: speed)
        synth.speak(utterance)
    }
}

/// Forwards synthesizer callbacks to the main actor by utterance identity.
private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private weak var owner: ReaderSpeech?

    init(owner: ReaderSpeech) { self.owner = owner }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.owner?.didStart(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.owner?.didFinish(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.owner?.didCancel(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.owner?.willSpeak(id, range: characterRange) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in self.owner?.systemPaused() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in self.owner?.systemContinued() }
    }
}

/// Remote commands (lock screen, Control Center, headphones, media keys) for the session that is
/// reading. Installed once, next to the podcast player's (whose handlers do nothing unless an episode
/// is playing); previous / next track step a sentence.
@MainActor
enum ReaderSpeechRemote {
    private(set) static weak var owner: ReaderSpeech?
    /// Now Playing shows this session (the podcast player took it over when it started).
    static var ownsNowPlaying = false
    private static var installed = false

    static func activate(_ speech: ReaderSpeech) {
        installIfNeeded()
        owner = speech
        ownsNowPlaying = true
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
    }

    static func deactivate(_ speech: ReaderSpeech) {
        guard owner === speech else { return }
        owner = nil
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        guard ownsNowPlaying else { return }
        ownsNowPlaying = false
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
        c.playCommand.addTarget(handler: handler { $0.resume() })
        c.pauseCommand.addTarget(handler: handler { $0.pause() })
        c.togglePlayPauseCommand.addTarget(handler: handler { $0.togglePlayPause() })
        c.nextTrackCommand.addTarget(handler: handler { $0.next() })
        c.previousTrackCommand.addTarget(handler: handler { $0.previous() })
    }

    /// Handlers are built outside the main actor (MediaPlayer may call them on any queue) and hop to it.
    nonisolated private static func handler(
        _ action: @escaping @MainActor @Sendable (ReaderSpeech) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in
                guard let owner = ReaderSpeechRemote.owner, owner.isActive else { return }
                action(owner)
            }
            return .success
        }
    }
}
