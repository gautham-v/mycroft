import OpenDispatchCore
import SwiftUI

/// YouTube item layout (VideoBody in reader.tsx). Theater: full-width black band above the title,
/// player up to 960pt. Otherwise the player sits in the text column under the title and meta row.
/// A Short skips the band: a 9:16 player centered in the column, above the title in theater, as tall
/// as the reader less room for the title to show under it. Under the description, Comments and Transcript
/// (if the video has captions) are tabs, Comments first; the theater band stays pinned at the top while it
/// scrolls, and once the tab bar scrolls up to it (or to the top of the reader) a copy of the bar pins there too.
struct ReaderVideoBody: View {
    let item: FeedItem
    let autoplay: Bool
    let theater: Bool
    let wide: Bool
    /// The reader's visible height; 0 until it's measured.
    let viewportHeight: CGFloat

    @State private var expanded = false
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
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.readerScroll) private var scroll

    private var vertical: Bool { item.item.isVerticalVideo }
    /// The column narrows it further when the window is narrow and tall.
    private var portraitWidth: CGFloat {
        max(Metrics.verticalVideoMinWidth, (viewportHeight - Metrics.verticalVideoTitleRoom) * 9 / 16)
    }
    private var summaryText: String { TextFormat.stripHTML(item.item.summary) }
    private var isLong: Bool {
        summaryText.count > 280 || summaryText.split(separator: "\n", omittingEmptySubsequences: false).count > 3
    }

    private var band: Bool { theater && !vertical && item.item.videoId != nil }

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
                .font(wide ? OFFont.videoTitleWide : OFFont.videoTitle)
                .tracking(-0.01 * (wide ? 22 : 20))
                .lineSpacing(2)
                .foregroundStyle(.ofInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 8) {
                ReaderFlowLayout(spacingX: 14, spacingY: 8) {
                    HStack(spacing: 8) {
                        SourceBadge(host: item.source.host, title: item.originName, size: 22)
                        Text(item.originName).fontWeight(.medium).foregroundStyle(.ofInk)
                    }
                    if let dur = TextFormat.duration(item.item.durationSec) {
                        Text(dur).monospacedDigit()
                    }
                    Text(TextFormat.date(item.item.publishedAt))
                }
                Spacer(minLength: 8)
                if let url = URL(string: item.item.url) {
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
            .padding(.top, 12)

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
                VStack(alignment: .leading, spacing: 6) {
                    Text(ReaderText.linkified(item.item.summary ?? ""))
                        .font(OFFont.ui(14.5))
                        .lineSpacing(14.5 * 0.4)
                        .foregroundStyle(.ofInk)
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLong {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain)
                            .font(OFFont.ui(13, .medium))
                            .foregroundStyle(.ofAccent)
                    }
                }
                .padding(.top, 20)
            }

            if showsComments || showsTranscript {
                tabBar
                    .opacity(tabsPinned ? 0 : 1)
                    // Switching tabs while pinned scrolls back to here: the top of the bar, less the band above it.
                    .background(alignment: .top) {
                        Color.clear.frame(height: headerHeight + 1).id(Self.tabsAnchor).padding(.top, -headerHeight)
                    }
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < pinLine - 0.5 } action: { tabsPinned = $0 }
                    .padding(.top, 28)
                tabContent
            }
        }
        .readerColumn(wide: wide)
        .padding(.top, theater ? 24 : (wide ? 40 : 32))
        .padding(.bottom, 32)
    }

    /// The theater band, or an empty header that only marks the top of the reader; the tab bar's pinned copy hangs under it.
    private var pinnedHeader: some View {
        Group {
            if band, let videoID = item.item.videoId {
                ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                                    thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec,
                                    resumeAt: resumeAt, controller: playback)
                    .frame(maxWidth: Metrics.theaterMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, wide ? 16 : 0)
                    .background(Color.black)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            pinLine = frame.maxY
            headerHeight = frame.height
        }
        .overlay(alignment: .bottom) {
            if tabsPinned {
                tabBar
                    .readerColumn(wide: wide)
                    .background(Color.ofSurface)
                    .alignmentGuide(.bottom) { $0[.top] }
            }
        }
    }

    private var tabBar: some View {
        ReaderVideoTabBar(tab: shownTab, comments: showsComments, commentCount: commentTotal,
                          transcript: showsTranscript, transcriptLoading: transcriptLoading, url: item.item.url,
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
}
