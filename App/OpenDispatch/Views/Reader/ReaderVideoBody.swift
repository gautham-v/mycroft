import OpenDispatchCore
import SwiftUI

/// YouTube item layout (VideoBody in reader.tsx). Theater: full-width black band above the title,
/// player up to 960pt. Otherwise the player sits in the text column under the title and meta row.
/// A Short skips the band: a 9:16 player centered in the column, above the title in theater, as tall
/// as the reader less room for the title to show under it. The transcript (if the video has captions)
/// follows the description; the theater band stays pinned at the top while it scrolls.
struct ReaderVideoBody: View {
    let item: FeedItem
    let autoplay: Bool
    let theater: Bool
    let wide: Bool
    /// The reader's visible height; 0 until it's measured.
    let viewportHeight: CGFloat

    @State private var expanded = false
    @State private var playback = ReaderYouTubeController()
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

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

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: band ? [.sectionHeaders] : []) {
            Section {
                column
            } header: {
                if band, let videoID = item.item.videoId {
                    ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                                        thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec,
                                        controller: playback)
                        .frame(maxWidth: Metrics.theaterMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, wide ? 16 : 0)
                        .background(Color.black)
                }
            }
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
                        SourceBadge(host: item.source.host, title: item.source.title, size: 22)
                        Text(item.source.title).fontWeight(.medium).foregroundStyle(.ofInk)
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
                                    controller: playback)
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

            if model.settings.videoTranscript, item.item.videoId != nil {
                ReaderVideoTranscript(item: item, playback: playback)
                    .padding(.top, 28)
            }
        }
        .readerColumn(wide: wide)
        .padding(.top, theater ? 24 : (wide ? 40 : 32))
        .padding(.bottom, 32)
    }

    private func portraitPlayer(_ videoID: String) -> some View {
        ReaderYouTubePlayer(videoID: videoID, title: item.item.title, autoplay: autoplay,
                            thumbnail: item.item.thumbnailUrl, durationSec: item.item.durationSec, vertical: true,
                            controller: playback)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: portraitWidth)
            .frame(maxWidth: .infinity)
    }
}
