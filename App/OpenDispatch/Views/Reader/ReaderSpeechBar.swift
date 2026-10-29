import OpenDispatchCore
import SwiftUI

/// The Read aloud player: previous sentence, play / pause, next sentence, the article's title with
/// elapsed / estimated total time, speed and close. A slim bar at the bottom of the reader pane (Mac,
/// iPad) or above the bottom safe area (iPhone).
struct ReaderSpeechBar: View {
    @Environment(ReaderSpeech.self) private var speech
    var compact: Bool

    private var buttonSize: CGFloat { compact ? Metrics.touchTarget : 32 }

    var body: some View {
        HStack(spacing: 2) {
            Button { speech.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 14))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .help("Previous sentence")
            .accessibilityLabel("Previous sentence")

            Button { speech.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.ofAccent)
                    Image(systemName: speech.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                .frame(width: compact ? 40 : 32, height: compact ? 40 : 32)
                .contentShape(Circle())
            }
            .help(speech.state == .playing ? "Pause" : "Play")
            .accessibilityLabel(speech.state == .playing ? "Pause reading" : "Resume reading")
            .accessibilityIdentifier("speech-play")

            Button { speech.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 14))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .help("Next sentence")
            .accessibilityLabel("Next sentence")

            VStack(alignment: .leading, spacing: 1) {
                Text(speech.title)
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeLine)
                    .font(OFFont.ui(11.5).monospacedDigit())
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .accessibilityElement(children: .combine)

            Menu {
                ForEach(ReaderPodcastPlayback.rates, id: \.self) { rate in
                    Button {
                        speech.setRate(rate)
                    } label: {
                        if rate == speech.rate {
                            Label(ReaderPodcastPlayback.rateLabel(rate), systemImage: OFIcon.check.rawValue)
                        } else {
                            Text(ReaderPodcastPlayback.rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(ReaderPodcastPlayback.rateLabel(speech.rate))
                    .font(OFFont.ui(12.5, .medium).monospacedDigit())
                    .foregroundStyle(.ofInk)
                    .padding(.horizontal, 8)
                    .frame(height: compact ? 32 : 26)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofHairline))
                    .frame(minHeight: compact ? Metrics.touchTarget : 0)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reading speed")
            .accessibilityLabel("Reading speed \(ReaderPodcastPlayback.rateLabel(speech.rate))")

            Button { speech.stop() } label: {
                OFIcon.close.image.font(.system(size: 14))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .help("Stop reading")
            .accessibilityLabel("Stop reading")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.ofInk)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 4 : 6)
        .background {
            Color.ofSurface.opacity(0.7)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
    }
}

extension ReaderSpeechBar {
    /// Elapsed / estimated total, or what the natural voice is waiting on.
    private var timeLine: String {
        if speech.preparing {
            switch speech.natural.phase {
            case .downloading: return "Downloading the natural voice…"
            case .loading: return "Loading the natural voice…"
            default: return "Preparing…"
            }
        }
        return "\(ReaderPodcastPlayback.clock(speech.elapsed)) / ~\(ReaderPodcastPlayback.clock(speech.total))"
    }
}

extension View {
    /// Read aloud for an article view: the player bar at the bottom while this page is being read, the
    /// Listen menu command, and the end of the session when the reader leaves the article or its text
    /// changes. `listen` starts or pauses (the toolbar button does the same).
    func readerSpeech(page: ReaderSpeechPage, pane: Int, compact: Bool, contentKey: String?,
                      listen: @escaping () -> Void) -> some View {
        modifier(ReaderSpeechModifier(page: page, pane: pane, compact: compact, contentKey: contentKey, listen: listen))
    }
}

private struct ReaderSpeechModifier: ViewModifier {
    let page: ReaderSpeechPage
    let pane: Int
    let compact: Bool
    let contentKey: String?
    let listen: () -> Void
    @Environment(ReaderSpeech.self) private var speech
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if speech.owns(page) { ReaderSpeechBar(compact: compact) }
            }
            .onChange(of: contentKey) { _, _ in speech.stop(ifOwnedBy: page) }
            .onChange(of: speech.commandToken) { _, _ in
                if model.focusedPane == pane { listen() }
            }
            .onDisappear { speech.stop(ifOwnedBy: page) }
    }
}
