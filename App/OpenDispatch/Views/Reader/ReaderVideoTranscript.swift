import OpenDispatchCore
import SwiftUI

/// The video's captions under its description, as paragraphs of 20 to 40 seconds. The paragraph
/// being played is in full ink, the rest muted; clicking one plays from there. The heading folds it
/// away (remembered across videos) and copies it. Nothing shows when the video has no captions.
struct ReaderVideoTranscript: View {
    let item: FeedItem
    let playback: ReaderYouTubeController

    @Environment(AppModel.self) private var model
    @State private var transcript: Transcript?
    @State private var paragraphs: [Transcript.Paragraph] = []
    @State private var loading = true

    private var collapsed: Bool { model.settings.videoTranscriptCollapsed }
    private var long: Bool { (paragraphs.last?.start ?? 0) >= 3600 }

    var body: some View {
        Group {
            if loading || transcript != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Color.ofHairline).frame(height: 1)
                    heading
                    if !collapsed, transcript != nil {
                        ReaderTranscriptParagraphs(paragraphs: paragraphs, long: long, playback: playback)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .task(id: item.id) {
            let found = await model.transcript(for: item)
            transcript = found
            paragraphs = found?.paragraphs ?? []
            loading = false
        }
    }

    private var heading: some View {
        HStack(spacing: 10) {
            Button {
                model.settings.videoTranscriptCollapsed.toggle()
            } label: {
                HStack(spacing: 7) {
                    OFIcon.chevron.image
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.ofMuted)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text("Transcript")
                        .font(OFFont.ui(15, .semibold))
                        .foregroundStyle(.ofInk)
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel(collapsed ? "Show transcript" : "Hide transcript")

            Spacer(minLength: 8)

            if let transcript {
                Button {
                    model.copyTranscript(transcript, durationSec: item.item.durationSec)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc").font(.system(size: 11.5))
                        Text("Copy")
                    }
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofInk)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofHairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Copy the transcript as Markdown")
            }
        }
        .padding(.vertical, 14)
    }
}

/// The paragraphs, lazily (a long video has hundreds). Only this view reads the playback time, so a
/// tick redraws the transcript and nothing else in the reader.
private struct ReaderTranscriptParagraphs: View {
    let paragraphs: [Transcript.Paragraph]
    let long: Bool
    let playback: ReaderYouTubeController

    /// The last paragraph that has started; nil before the first one (or with no timing at all).
    private var current: Int? {
        let time = playback.time
        var lo = 0, hi = paragraphs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if let start = paragraphs[mid].start, start <= time + 0.5 { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 && paragraphs[lo - 1].start != nil ? lo - 1 : nil
    }

    var body: some View {
        let current = current
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(paragraphs.indices, id: \.self) { i in
                ReaderTranscriptRow(paragraph: paragraphs[i], long: long, isCurrent: i == current) { start in
                    playback.play(from: start)
                }
            }
        }
    }
}

private struct ReaderTranscriptRow: View {
    let paragraph: Transcript.Paragraph
    let long: Bool
    let isCurrent: Bool
    let play: (Double) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(paragraph.start.map(stamp) ?? "")
                .font(OFFont.ui(12.5, isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Color.ofAccent : Color.ofFaint)
                .frame(width: long ? 58 : 44, alignment: .leading)
            text
                .font(OFFont.ui(15))
                .lineSpacing(15 * 0.4)
                .foregroundStyle(isCurrent ? Color.ofInk : Color.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(hovering && paragraph.start != nil ? Color.ofHover : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let start = paragraph.start { play(start) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(paragraph.start != nil ? .isButton : [])
        .accessibilityHint(paragraph.start != nil ? "Plays from here" : "")
    }

    private var text: Text {
        guard let speaker = paragraph.speaker else { return Text(paragraph.text) }
        return Text("\(Text(speaker + ": ").fontWeight(.semibold))\(paragraph.text)")
    }

    private func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return long ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", h * 60 + m, sec)
    }
}
