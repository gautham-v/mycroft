import OpenDispatchCore
import SwiftUI

/// YouTube item layout (VideoBody in reader.tsx). Theater: full-width black band above the title, the
/// player as tall as the reader less room for the title row (at least 960pt wide, if the reader is that wide);
/// scrolling down snaps the pinned band to under half the reader so the description and comments have room,
/// and scrolling back to the top grows it again. Otherwise the player sits in the text column under the title and meta row.
/// A Short skips the band: a 9:16 player centered in the column, above the title in theater, as tall
/// as the reader less room for the title to show under it. Under the description, Comments and Transcript
/// (if the video has captions) are tabs, Comments first; the theater band stays pinned at the top while it
/// scrolls, and once the tab bar scrolls up to it (or to the top of the reader) a copy of the bar pins there too.
/// A reader narrower than `Metrics.narrowVideoReader` tightens it all: smaller title, description and tabs, no date,
/// Watch on YouTube as its icon, and comments in smaller type whose author lines wrap instead of cutting off.
struct ReaderVideoBody: View {
    let item: FeedItem
    let autoplay: Bool
    let theater: Bool
    let wide: Bool
    /// The reader's visible height; 0 until it's measured.
    let viewportHeight: CGFloat

    @State private var expanded = false
    /// The description is cut to its first lines.
    @State private var summaryCut = false
    @State private var width: CGFloat = 0
    @State private var playback = ReaderYouTubeController()
    @State private var tab: ReaderVideoTab = .comments
    @State private var transcript: Transcript?
    @State private var paragraphs: [Transcript.Paragraph] = []
    @State private var transcriptLoading = true
    @State private var commentTotal: Int?
    /// Where the pinned header (the theater band, or nothing) ends on screen, and its height.
    @State private var pinLine: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    /// The tab bar has scrolled up past `pinLine`, so its pinned copy shows.
    @State private var tabsPinned = false
    /// Where the header sits on screen at its pinned place, and whether the band has snapped to its pinned height.
    @State private var headerTop: CGFloat = 0
    @State private var bandSmall = false
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.readerScroll) private var scroll

    private var vertical: Bool { item.item.isVerticalVideo }
    /// The column narrows it further when the window is narrow and tall.
    private var portraitWidth: CGFloat {
        max(Metrics.verticalVideoMinWidth, (viewportHeight - Metrics.verticalVideoTitleRoom) * 9 / 16)
    }
    private var summaryText: String { TextFormat.stripHTML(item.item.summary) }
    /// 0 until measured, which counts as wide.
    private var narrow: Bool { width > 0 && width < Metrics.narrowVideoReader }

    private var band: Bool { theater && !vertical && item.item.videoId != nil }

    /// The band player's full and pinned heights; nil until the reader is measured.
    private var bandHeights: (full: CGFloat, pinned: CGFloat)? {
        guard band, width > 0 else { return nil }
        let room = max(0, width - (wide ? 32 : 0))
        let capped = min(room, Metrics.theaterMaxWidth) * 9 / 16
        let full = max(capped, min(room * 9 / 16, viewportHeight - Metrics.theaterTitleRoom))
        return (full, min(full, max(Metrics.theaterPinnedMin, viewportHeight * Metrics.theaterPinnedShare)))
    }
    private var bandPlayerHeight: CGFloat? { bandHeights.map { bandSmall ? $0.pinned : $0.full } }

    private var showsComments: Bool { model.settings.showComments && item.item.videoId != nil }
    private var showsTranscript: Bool {
        model.settings.videoTranscript && item.item.videoId != nil && (transcriptLoading || transcript != nil)
    }
    /// The chosen tab, or the other one when it's off (no captions, or turned off in Settings).
    private var shownTab: ReaderVideoTab {
        switch tab {
        case .comments: showsComments ? .comments : .transcript
        case .transcript: transcript != nil ? .transcript : .comments
        }
    }

    private static let tabsAnchor = "videoTabs"

    /// Where a video watched partway starts again.
    private var resumeAt: Double? { model.history.resumePosition(item) }

    /// History: how far it got, every few seconds while playing and once more on leaving.
    private func recordProgress(force: Bool = false) {
        model.history.recordProgress(item, position: playback.time, duration: playback.duration, force: force)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                column
            } header: {
                pinnedHeader
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Scrolling down snaps the band to its pinned height, and the page moves up under it; at the top it grows back.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            guard bandHeights != nil else { return }
            let scrolled = headerTop - top
            let small = bandSmall ? scrolled >= 1 : scrolled > Metrics.theaterSnapScroll
            if small != bandSmall { withAnimation(.smooth(duration: 0.3)) { bandSmall = small } }
        }
        .environment(\.readerNarrow, narrow)
        .task(id: model.settings.videoTranscript) {
            guard model.settings.videoTranscript, item.item.videoId != nil else {
                transcriptLoading = false
                return
            }
            transcriptLoading = true
            let found = await model.transcript(for: item)
            transcript = found
            paragraphs = found?.paragraphs ?? []
            transcriptLoading = false
        }
        .onChange(of: playback.time) { _, _ in recordProgress() }
        .onChange(of: model.autoplayItemID) { _, id in
            // Clicking the video already shown as the list's first item opens it: play it now.
            if autoplay, id == item.id, playback.webView == nil { playback.start?(resumeAt ?? 0) }
        }
        .onDisappear {
            recordProgress(force: true)
            playback.stop()
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            if theater, vertical, let videoID = item.item.videoId {
                portraitPlayer(videoID)
                    .padding(.bottom, 24)
            }

            Text(item.item.title)
                .font(narrow ? OFFont.videoTitleNarrow : wide ? OFFont.videoTitleWide : OFFont.videoTitle)
                .tracking(-0.01 * (narrow ? 15 : wide ? 22 : 20))
                .lineSpacing(2)
                .foregroundStyle(.ofInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 8) {
                ReaderFlowLayout(spacingX: 14, spacingY: 8) {
                    HStack(spacing: 8) {
                        SourceBadge(host: item.source.host, title: item.originName, size: 22)
                        Text(item.originName).fontWeight(.medium).foregroundStyle(.ofInk)
                            .lineLimit(narrow ? 1 : nil)
                    }
                    if !narrow {
                        if let dur = TextFormat.duration(item.item.durationSec) {
                            Text(dur).monospacedDigit()
                        }
                        Text(TextFormat.date(item.item.publishedAt))
                    }
                }
                Spacer(minLength: 8)
                if let url = URL(string: item.item.url), narrow {
                    Button { openURL(url) } label: {
                        OFIcon.external.image
                            .font(.system(size: 13))
                            .foregroundStyle(.ofMuted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Watch on YouTube")
                    .accessibilityLabel("Watch on YouTube")
                } else if let url = URL(string: item.item.url) {
                    Button { openURL(url) } label: {
                        HStack(spacing: 6) {
                            Text("Watch on YouTube")
                            OFIcon.external.image.font(.system(size: 12))
                        }
                        .font(OFFont.ui(12.5))
                        .foregroundStyle(.ofInk)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofHairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .padding(.top, narrow ? 8 : 12)

            if !theater, vertical, let videoID = item.item.videoId {
                portraitPlayer(videoID)
                    .padding(.top, 20)
            } else if !theater, let videoID = item.item.videoId {
                ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                                    thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec,
                                    resumeAt: resumeAt, controller: playback)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 20)
            }

            if !summaryText.isEmpty {
                let size: CGFloat = narrow ? 13.5 : 14.5
                VStack(alignment: .leading, spacing: 6) {
                    Text(ReaderText.linkified(item.item.summary ?? ""))
                        .font(OFFont.ui(size))
                        .lineSpacing(size * 0.4)
                        .foregroundStyle(.ofInk)
                        .textSelection(.enabled)
                        .readerClamped(expanded ? nil : (narrow ? 2 : 3), truncated: $summaryCut)
                    if summaryCut || expanded {
                        ReaderDisclosureButton(title: expanded ? "Show less" : "Show more", open: expanded, size: 13) {
                            expanded.toggle()
                        }
                    }
                }
                .padding(.top, narrow ? 12 : 20)
            }

            if showsComments || showsTranscript {
                tabBar
                    .opacity(tabsPinned ? 0 : 1)
                    // Switching tabs while pinned scrolls back to here: the top of the bar, less the band above it.
                    .background(alignment: .top) {
                        Color.clear.frame(height: headerHeight + 1).id(Self.tabsAnchor).padding(.top, -headerHeight)
                    }
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < pinLine - 0.5 } action: { tabsPinned = $0 }
                    .padding(.top, narrow ? 18 : 28)
                tabContent
            }
        }
        .readerColumn(wide: wide, padding: narrow ? Metrics.readerPaddingNarrow : nil)
        .padding(.top, narrow ? 16 : theater ? 24 : (wide ? 40 : 32))
        .padding(.bottom, 32)
    }

    /// The theater band, or an empty header that only marks the top of the reader; the tab bar's pinned copy hangs under it.
    private var pinnedHeader: some View {
        Group {
            if band, let videoID = item.item.videoId {
                ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                                    thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec,
                                    resumeAt: resumeAt, controller: playback)
                    .frame(maxWidth: bandPlayerHeight.map { $0 * 16 / 9 } ?? Metrics.theaterMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, wide ? 16 : 0)
                    .background(Color.black)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            headerTop = frame.minY
            pinLine = frame.maxY
            headerHeight = frame.height
        }
        .overlay(alignment: .bottom) {
            if tabsPinned {
                tabBar
                    .readerColumn(wide: wide, padding: narrow ? Metrics.readerPaddingNarrow : nil)
                    .background(Color.ofSurface)
                    .alignmentGuide(.bottom) { $0[.top] }
            }
        }
    }

    private var tabBar: some View {
        ReaderVideoTabBar(tab: shownTab, comments: showsComments, commentCount: commentTotal,
                          transcript: showsTranscript, transcriptLoading: transcriptLoading, url: item.item.url, compact: narrow,
                          copy: transcript.map { found in { model.copyTranscript(found, durationSec: item.item.durationSec) } },
                          select: select)
    }

    /// The comments stay loaded (and folded as they were) while the transcript shows.
    @ViewBuilder private var tabContent: some View {
        if showsComments {
            ReaderComments(url: item.item.url, place: .youtube, heading: false) { commentTotal = $0 }
                .id(item.id)
                .padding(.top, 6)
                .frame(height: shownTab == .comments ? nil : 0, alignment: .top)
                .clipped()
                .opacity(shownTab == .comments ? 1 : 0)
                .allowsHitTesting(shownTab == .comments)
                .accessibilityHidden(shownTab != .comments)
        }
        if shownTab == .transcript, transcript != nil {
            ReaderTranscriptParagraphs(paragraphs: paragraphs, long: (paragraphs.last?.start ?? 0) >= 3600, playback: playback)
                .padding(.top, 10)
        }
    }

    /// Picks a tab; with the bar pinned, scrolls back to the start of it, as the old tab's place means nothing in the new one.
    private func select(_ value: ReaderVideoTab) {
        let pinned = tabsPinned
        tab = value
        guard pinned else { return }
        DispatchQueue.main.async { scroll?.scrollTo(Self.tabsAnchor, anchor: .top) }
    }

    private func portraitPlayer(_ videoID: String) -> some View {
        ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                            thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec, vertical: true,
                            resumeAt: resumeAt, controller: playback)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: portraitWidth)
            .frame(maxWidth: .infinity)
    }
}

extension EnvironmentValues {
    /// The reader's scroll view, for a view inside it to scroll to one of its ids.
    @Entry var readerScroll: ScrollViewProxy? = nil
    /// The video reader is narrower than `Metrics.narrowVideoReader`: its comments use smaller type.
    @Entry var readerNarrow = false
}
