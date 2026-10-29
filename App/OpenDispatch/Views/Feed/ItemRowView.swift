import OpenDispatchCore
import SwiftUI

/// One list row. Port of src/components/item-row.tsx.
///
/// Article/video/podcast rows: 16pt badge + "Source · 3h", then the title (14.5/500) with an optional
/// 64×42 thumbnail on the right. Posts on X lead with the author ("Name @handle · 3h"), then up to two
/// lines of text and (macOS/iPad) a one-line snippet, or for a quote post the quoted account and text
/// (QuoteLine), with the post's first photo or video as the thumbnail.
///
/// iPhone rows put the headline first (17 semibold, a post's text 17 regular, up to three lines) and the
/// badge with "Source · 3h" under it, beside an 80pt square thumbnail; a YouTube video with a thumbnail
/// instead leads with it full width at 16:9. No snippet. A topic's Hacker News or Reddit row adds its points and
/// comments to the meta line ("Hacker News · 1d · ▲ 15 · 💬 4", drawn with SF Symbols; `DiscussionStats`). A news story with other
/// outlets or a discussion behind it is a `StoryRowView` instead.
///
/// The row draws its own rounded background (selected / the other pane's item / hovered) and leaves
/// the inset hairline to `ItemListView`, which knows the neighbours. Equatable so a hover or selection
/// change elsewhere in the list doesn't re-render every row.
struct ItemRowView: View, Equatable {
    let item: FeedItem
    var isSelected = false
    /// The item open in the other pane of the split view: a lighter highlight with a hairline outline.
    var isSecondary = false
    /// Open in a background tab (and not shown in either pane): a dot at the end of the meta line.
    var isOpenInTab = false
    var isHovered = false
    /// iPhone: the roomier headline-first layout (`phoneRow`).
    var isPhone = false
    /// Read (HistoryStore): the title goes grey (and on iPhone loses its weight), the art and badge fade.
    var isRead = false
    /// A video or episode in progress: how far, drawn as a line along the bottom of the thumbnail.
    var progress: Double?
    /// Replaces the relative publish time in the meta line (History shows when it was opened).
    var timeText: String?
    /// A topic's item leads its meta line with the topic's keyword ("OpenAI · The Verge"), as in Saved and
    /// History; inside the topic's own list that is dropped and only the origin shows.
    var showsTopic = true
    /// The article's site wants a subscription (Settings → Integrations → Paywalled articles): a lock and "Subscribers" end
    /// the meta line, and the title is a little quieter. `.free` for no mark.
    var paywall: PaywallStatus = .free

    /// Settings → Appearance → Lists.
    @Environment(\.listLayout) private var layout

    /// The row's own values; the environment's list layout re-renders it by itself.
    nonisolated static func == (a: ItemRowView, b: ItemRowView) -> Bool {
        a.item == b.item && a.isSelected == b.isSelected && a.isSecondary == b.isSecondary && a.isOpenInTab == b.isOpenInTab
            && a.isHovered == b.isHovered && a.isPhone == b.isPhone && a.isRead == b.isRead && a.progress == b.progress
            && a.timeText == b.timeText && a.showsTopic == b.showsTopic && a.paywall == b.paywall
    }

    /// Read and drawn as read: with Unread marker set to None, read rows look like the rest.
    private var dimsRead: Bool { isRead && layout.unreadMarker != .none }
    private var titleColor: Color { dimsRead ? .ofRead : paywall.markLabel != nil ? .ofBody : .ofInk }

    var body: some View {
        Group {
            if isPhone {
                phoneRow
            } else if TextFormat.isSocialPost(item.item.url) {
                postRow
            } else {
                articleRow
            }
        }
        .itemRowChrome(isSelected: isSelected, isSecondary: isSecondary, isHovered: isHovered, isPhone: isPhone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Layouts

    private var articleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaLine(name: sourceName, handle: nil)
            HStack(alignment: .top, spacing: 12) {
                Text(item.item.title)
                    .font(OFFont.itemTitle)
                    .tracking(-0.07)
                    .lineSpacing(2)
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                thumbnail(.compact)
            }
        }
    }

    private var postRow: some View {
        let (name, handle) = TextFormat.splitHandle(item.item.author)
        return VStack(alignment: .leading, spacing: 4) {
            metaLine(name: name.isEmpty ? sourceName : name, handle: handle)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.item.title)
                        .font(OFFont.ui(14.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                    if !isPhone, let snippet {
                        if let quote = QuoteLine.parse(snippet, avatar: item.item.quoteAvatarUrl) {
                            quote
                        } else {
                            Text(snippet)
                                .font(OFFont.itemSnippet)
                                .foregroundStyle(.ofMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                thumbnail(.compact)
            }
        }
    }

    /// iPhone: headline, then the meta line; beside a square thumbnail, or under a full-width video frame.
    @ViewBuilder private var phoneRow: some View {
        let isPost = TextFormat.isSocialPost(item.item.url)
        let (name, handle) = isPost ? TextFormat.splitHandle(item.item.author) : ("", nil)
        let text = VStack(alignment: .leading, spacing: 8) {
            Text(item.item.title)
                .font(isPost || dimsRead ? OFFont.phonePostText : OFFont.phoneItemTitle)
                .tracking(isPost ? -0.2 : -0.3)
                .lineSpacing(2)
                .foregroundStyle(titleColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            metaLine(name: name.isEmpty ? sourceName : name, handle: handle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if !isPost && item.source.kind == .youtube && item.item.thumbnailUrl?.isEmpty == false && layout.thumbnails != .off {
            VStack(alignment: .leading, spacing: 12) {
                thumbnail(.wide)
                text
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                text
                thumbnail(.square)
            }
        }
    }

    @ViewBuilder private func thumbnail(_ style: ItemThumbnail.Style) -> some View {
        if layout.thumbnails != .off {
            ItemThumbnail(item: item, style: style, progress: progress, scale: layout.thumbnailScale)
                .opacity(dimsRead ? 0.55 : 1)
        }
    }

    /// Badge, then the source (or author) and the rest, all muted, truncated on one line.
    private func metaLine(name: String, handle: String?) -> some View {
        HStack(spacing: 6) {
            if !isRead && layout.unreadMarker == .dot { UnreadDot() }
            SourceBadge(host: item.source.host, title: item.originName, size: Metrics.rowBadge)
                .opacity(dimsRead ? 0.6 : 1)
            metaText(name: name, handle: handle)
                .lineLimit(1)
                .truncationMode(.tail)
            if isOpenInTab && !isPhone {
                Spacer(minLength: 0)
                Circle()
                    .fill(Color.ofAccent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private func metaText(name: String, handle: String?) -> Text {
        let line = name + (handle.map { " @\($0)" } ?? "") + " · " + (timeText ?? RelativeTime.format(item.item.publishedAt))
        let base = Text(verbatim: line)
        var text = DiscussionStats.text(item: item.item, isTopicItem: item.source.isTopic).map { Text("\(base)\(Text(verbatim: " \u{00B7} "))\($0)") } ?? base
        if let mark = paywall.markText { text = Text("\(text)\(Text(verbatim: " \u{00B7} "))\(mark)") }
        return text.font(isPhone ? OFFont.phoneItemMeta : OFFont.itemMeta).foregroundStyle(Color.ofMuted)
    }

    /// Where the item is from, as its meta line names it: the source, or for a topic's item the origin (Hacker News, a
    /// publisher, a channel, a show) with the topic's keyword in front outside the topic's list.
    private var sourceName: String {
        guard item.source.isTopic else { return item.source.title }
        return showsTopic ? "\(item.source.title) \u{00B7} \(item.originName)" : item.originName
    }

    private var snippet: String? {
        let s = TextFormat.stripHTML(item.item.summary)
        return s.isEmpty ? nil : s
    }

    private var accessibilityText: String {
        var parts = [item.item.title, sourceName, RelativeTime.format(item.item.publishedAt)]
        if item.source.kind == .youtube { parts.append("Video") }
        if item.source.kind == .podcast { parts.append("Podcast episode") }
        if let d = TextFormat.duration(item.item.durationSec) { parts.append(d) }
        if let stats = DiscussionStats.spoken(item: item.item, isTopicItem: item.source.isTopic) { parts.append(stats) }
        if let label = paywall.markLabel { parts.append(label) }
        if item.isSaved { parts.append("Saved") }
        if isRead { parts.append(item.source.kind == .youtube ? "Watched" : "Read") }
        if let progress { parts.append("\(Int(progress * 100))% played") }
        if isOpenInTab { parts.append("Open in a tab") }
        return parts.joined(separator: ", ")
    }
}

extension PaywallStatus {
    /// The words of a list row's mark; nil for a site with no mark (free, or signed in).
    var markLabel: String? {
        switch self {
        case .walled: "Subscribers"
        case .metered: "May need sign-in"
        case .free, .signedIn: nil
        }
    }

    /// The mark for a meta line: a lock and its words, drawn with an SF Symbol.
    var markText: Text? {
        markLabel.map { Text("\(Text(Image(systemName: OFIcon.lock.rawValue)).font(.system(size: 10)))\(Text(verbatim: " " + $0))") }
    }
}

extension View {
    /// A list row's frame: full width, the row padding and the rounded background (selected / the other pane's item /
    /// hovered) that `ItemRowView` and `StoryRowView` share.
    func itemRowChrome(isSelected: Bool, isSecondary: Bool, isHovered: Bool, isPhone: Bool) -> some View {
        modifier(ItemRowChrome(isSelected: isSelected, isSecondary: isSecondary, isHovered: isHovered, isPhone: isPhone))
    }

}

private struct ItemRowChrome: ViewModifier {
    let isSelected: Bool
    let isSecondary: Bool
    let isHovered: Bool
    let isPhone: Bool
    @Environment(\.listLayout) private var layout

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isPhone ? Metrics.phoneRowPaddingH : Metrics.rowPaddingH)
            .padding(.vertical, layout.rowPaddingV(phone: isPhone))
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(isSelected ? Color.ofSelection : isHovered || isSecondary ? Color.ofHover : Color.clear)
            )
            .overlay {
                if isSecondary && !isSelected {
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .strokeBorder(Color.ofHairline, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
    }
}

/// The quoted post under a quote post on X: a turn arrow, the quoted account's avatar (a monogram until
/// it loads, or when the post was fetched before avatars were kept), its name and the first line of
/// its text, with t.co links dropped. Built from the summary the scraper writes ("Quoting Name: text").
struct QuoteLine: View {
    let name: String
    let text: String
    let avatar: URL?
    @Environment(\.displayScale) private var displayScale

    private static let size: CGFloat = 14
    private static let tco = try! NSRegularExpression(pattern: #"\s*https?://t\.co/\S*"#)

    static func parse(_ summary: String, avatar: String?) -> QuoteLine? {
        guard summary.hasPrefix("Quoting "), let colon = summary.range(of: ": ") else { return nil }
        let name = String(summary[summary.index(summary.startIndex, offsetBy: 8)..<colon.lowerBound])
        let raw = String(summary[colon.upperBound...])
        let text = tco.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return QuoteLine(name: name, text: text, avatar: avatar.flatMap(URL.init(string:)))
    }

    var body: some View {
        HStack(spacing: 6) {
            OFIcon.quoted.image
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.ofFaint)
            avatarView
            Text("\(Text(verbatim: name).foregroundStyle(Color.ofInk.opacity(0.82)))\(Text(verbatim: text.isEmpty ? "" : "  " + text))")
                .font(OFFont.itemSnippet)
                .foregroundStyle(.ofMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var avatarView: some View {
        CachedAsyncImage(url: avatar, maxPixelSize: Self.size * max(displayScale, 2)) { image in
            image.resizable().scaledToFill()
        } placeholder: { _ in
            ZStack {
                Color.ofCode
                Text(verbatim: String(name.prefix(1)).uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.ofMuted)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The 64×42 thumbnail (item-row.tsx `Thumb`), or on iPhone an 80pt square or a full-width 16:9 video
/// frame. Podcast rows keep one without art so the audio indicator and duration still show; YouTube gets
/// a play glyph; videos and podcasts show the duration badge.
struct ItemThumbnail: View {
    enum Style { case compact, square, wide }

    let item: FeedItem
    var style: Style = .compact
    /// A video or episode in progress (0...1): a line along the bottom edge.
    var progress: Double?
    /// Settings → Appearance → Lists → Thumbnails: Large draws the compact and square styles bigger.
    var scale: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    private var progressHeight: CGFloat { isWide ? 4 : 3 }

    private var isPodcast: Bool { item.source.kind == .podcast }
    private var isVideo: Bool { item.source.kind == .youtube }
    private var thumbURL: URL? {
        guard let s = item.item.thumbnailUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var isWide: Bool { style == .wide }
    /// Largest side drawn, in points (the wide frame is at most a phone's width less the row padding).
    private var pointSize: CGFloat {
        switch style {
        case .compact: Metrics.thumbWidth * scale
        case .square: Metrics.phoneThumb * scale
        case .wide: 400
        }
    }
    private var radius: CGFloat {
        switch style {
        case .compact: Metrics.thumbRadius
        case .square: Metrics.phoneThumbRadius
        case .wide: Metrics.phoneVideoRadius
        }
    }

    var body: some View {
        if thumbURL != nil || isPodcast {
            thumb
        }
    }

    private var thumb: some View {
        sized(Color.ofCode)
        .overlay {
            if let url = thumbURL {
                CachedAsyncImage(url: url, maxPixelSize: pointSize * max(displayScale, 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { failed in
                    if failed && isPodcast { headphonesPlaceholder } else { Color.ofCode }
                }
            } else {
                headphonesPlaceholder
            }
        }
        .overlay {
            if isVideo {
                let d: CGFloat = isWide ? 48 : style == .square ? 26 : 20
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: d, height: d)
                    .overlay(
                        OFIcon.play.image
                            .font(.system(size: d * 0.4, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: d * 0.025)
                    )
            }
        }
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if isPodcast && thumbURL != nil {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 14, height: 14)
                    .overlay(
                        OFIcon.headphones.image
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .padding(2)
                    .accessibilityLabel("Podcast episode")
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.4))
                        Rectangle().fill(Color.white).frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: progressHeight)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if (isVideo || isPodcast), let dur = TextFormat.duration(item.item.durationSec) {
                Text(dur)
                    .font(isWide ? OFFont.videoThumbBadge : OFFont.thumbBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, isWide ? 6 : 4)
                    .frame(height: isWide ? 20 : 14)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: isWide ? 6 : 4, style: .continuous))
                    .padding(isWide ? 8 : 2)
                    .padding(.bottom, progress != nil ? progressHeight : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The frame the art fills: 64×42, an 80pt square, or full width at 16:9.
    @ViewBuilder private func sized(_ base: some View) -> some View {
        switch style {
        case .compact: base.frame(width: (Metrics.thumbWidth * scale).rounded(), height: (Metrics.thumbHeight * scale).rounded())
        case .square: base.frame(width: (Metrics.phoneThumb * scale).rounded(), height: (Metrics.phoneThumb * scale).rounded())
        case .wide: base.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
        }
    }

    private var headphonesPlaceholder: some View {
        OFIcon.headphones.image
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.ofFaint)
    }
}

/// Loading placeholder rows (ListSkeleton in openfeed-app.tsx): 8 rows of pulsing blocks.
struct ItemSkeletonRow: View {
    @State private var dim = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.ofCode)
                .frame(width: 24, height: 24)
                .padding(.top, 1)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.ofCode)
                        .frame(width: geo.size.width * 0.85, height: 16)
                    RoundedRectangle(cornerRadius: 4).fill(Color.ofCode)
                        .frame(width: geo.size.width * 0.4, height: 12)
                }
            }
            .frame(height: 36)
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
        .opacity(dim ? 0.5 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Rows") {
    let model = AppModel.preview()
    let source = Source(id: 1, title: "Simon Willison", url: "https://simonwillison.net", feedUrl: "https://simonwillison.net/atom/everything/", kind: .rss, group: "blogs")
    let video = Source(id: 2, title: "Two Minute Papers", url: "https://www.youtube.com/@TwoMinutePapers", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=x", kind: .youtube, group: "youtube")
    let a = FeedItem(item: Item(id: 1, sourceId: 1, guid: "a", url: "https://simonwillison.net/a", title: "Notes on running a local model for structured extraction", summary: "<p>Some summary text that runs on for a while to show the snippet clamp on phones.</p>", publishedAt: Date().addingTimeInterval(-3_600)), source: source)
    let v = FeedItem(item: Item(id: 2, sourceId: 2, guid: "v", url: "https://www.youtube.com/watch?v=x", title: "This new AI renders light in real time", publishedAt: Date().addingTimeInterval(-86_400), thumbnailUrl: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", durationSec: 425), source: video)
    return VStack(spacing: 0) {
        ItemRowView(item: a, isSelected: true, isPhone: true)
        ItemRowView(item: v)
        ItemSkeletonRow()
    }
    .padding(8)
    .frame(width: 410)
    .background(Color.ofSurface)
    .environment(model)
}
