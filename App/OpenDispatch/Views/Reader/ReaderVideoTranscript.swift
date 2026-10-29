import OpenDispatchCore
import SwiftUI

/// The two tabs under a video's description. Comments is shown first.
enum ReaderVideoTab { case comments, transcript }

/// The Comments | Transcript bar under a video's description: the tabs that are on (with the comment count, and a spinner
/// while the captions load), then "On YouTube" for comments or Copy for the transcript, over a hairline. The reader keeps a
/// second copy of it pinned at the top while you scroll the tab's content (`ReaderVideoBody`).
struct ReaderVideoTabBar: View {
    let tab: ReaderVideoTab
    let comments: Bool
    let commentCount: Int?
    let transcript: Bool
    let transcriptLoading: Bool
    let url: String
    let copy: (() -> Void)?
    let select: (ReaderVideoTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                if comments { tabButton(.comments, "Comments", count: commentCount) }
                if transcript { tabButton(.transcript, "Transcript", loading: transcriptLoading) }
                Spacer(minLength: 8)
                trailing
            }
            Rectangle().fill(Color.ofHairline).frame(height: 1)
        }
    }

    private func tabButton(_ value: ReaderVideoTab, _ title: String, count: Int? = nil, loading: Bool = false) -> some View {
        let on = tab == value
        return Button { select(value) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(OFFont.ui(15, .semibold))
                    .foregroundStyle(on ? Color.ofInk : Color.ofMuted)
                if let count, count > 0 {
                    Text(ExploreFormat.count(count))
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofFaint)
                        .monospacedDigit()
                }
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.top, 13)
            .padding(.bottom, 11)
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(Color.ofInk).frame(height: 2).offset(y: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var trailing: some View {
        if tab == .comments, let link = URL(string: url) {
            Link(destination: link) {
                HStack(spacing: 5) {
                    Text("On YouTube")
                    OFIcon.external.image.font(.system(size: 11))
                }
                .font(OFFont.ui(12.5))
                .foregroundStyle(.ofMuted)
            }
            .buttonStyle(.plain)
            .help("Open the comments in your browser")
        } else if tab == .transcript, let copy {
            Button(action: copy) {
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
}

/// The video's captions in the Transcript tab, as paragraphs of 20 to 40 seconds. The paragraph being played is in full
/// ink, the rest muted; clicking one plays from there. Lazily (a long video has hundreds), and only this view reads the
/// playback time, so a tick redraws the transcript and nothing else in the reader.
struct ReaderTranscriptParagraphs: View {
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
