import OpenfeedCore
import SwiftUI

/// One list row. Port of src/components/item-row.tsx.
///
/// Article/video/podcast rows: 16pt badge + "Source · 3h", then the title (14.5/500) with an optional
/// 64×42 thumbnail on the right. Posts on X lead with the author ("Name @handle · 3h"), then up to two
/// lines of text and (macOS/iPad) a one-line snippet, or for a quote post the quoted account and text
/// (QuoteLine). iPhone rows are headline only: no snippet, and
/// the meta line adds HN points and comments when present.
///
/// The row draws its own rounded background (selected / hovered) and leaves the inset hairline to
/// `ItemListView`, which knows the neighbours. Equatable so a hover or selection change elsewhere in
/// the list doesn't re-render every row.
struct ItemRowView: View, Equatable {
    let item: FeedItem
    var isSelected = false
    var isHovered = false
    /// iPhone: headline-only rows (no snippet) with HN points/comments in the meta line.
    var isPhone = false

    var body: some View {
        Group {
            if TextFormat.isXPost(item.item.url) {
                postRow
            } else {
                articleRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(isSelected ? Color.ofSelection : isHovered ? Color.ofHover : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Layouts

    private var articleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaLine(name: item.source.title, handle: nil)
            HStack(alignment: .top, spacing: 12) {
                Text(item.item.title)
                    .font(OFFont.itemTitle)
                    .tracking(-0.07)
                    .lineSpacing(2)
                    .foregroundStyle(.ofInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                ItemThumbnail(item: item)
            }
        }
    }

    private var postRow: some View {
        let (name, handle) = TextFormat.splitHandle(item.item.author)
        return VStack(alignment: .leading, spacing: 4) {
            metaLine(name: name.isEmpty ? item.source.title : name, handle: handle)
            Text(item.item.title)
                .font(OFFont.ui(14.5))
                .lineSpacing(2.5)
                .foregroundStyle(.ofInk)
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
    }

    /// Badge, then the source (or author) and the rest, all muted, truncated on one line.
    private func metaLine(name: String, handle: String?) -> some View {
        HStack(spacing: 6) {
            SourceBadge(host: item.source.host, title: item.source.title, size: Metrics.rowBadge)
            metaText(name: name, handle: handle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func metaText(name: String, handle: String?) -> Text {
        var line = name + (handle.map { " @\($0)" } ?? "") + " · " + RelativeTime.format(item.item.publishedAt)
        if isPhone {
            if let points = item.item.hnPoints { line += " · \(points) points" }
            if let comments = item.item.hnComments { line += " · \(comments) comments" }
        }
        return Text(verbatim: line).font(OFFont.itemMeta).foregroundStyle(Color.ofMuted)
    }

    private var snippet: String? {
        let s = TextFormat.stripHTML(item.item.summary)
        return s.isEmpty ? nil : s
    }

    private var accessibilityText: String {
        var parts = [item.item.title, item.source.title, RelativeTime.format(item.item.publishedAt)]
        if item.source.kind == .youtube { parts.append("Video") }
        if item.source.kind == .podcast { parts.append("Podcast episode") }
        if let d = TextFormat.duration(item.item.durationSec) { parts.append(d) }
        if item.isSaved { parts.append("Saved") }
        return parts.joined(separator: ", ")
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

/// The 64×42 thumbnail (item-row.tsx `Thumb`). Podcast rows keep one without art so the audio
/// indicator and duration still show; YouTube gets a play glyph; videos and podcasts show the
/// duration badge.
struct ItemThumbnail: View {
    let item: FeedItem
    @Environment(\.displayScale) private var displayScale

    private var isPodcast: Bool { item.source.kind == .podcast }
    private var isVideo: Bool { item.source.kind == .youtube }
    private var thumbURL: URL? {
        guard let s = item.item.thumbnailUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var body: some View {
        if thumbURL != nil || isPodcast {
            thumb
        }
    }

    private var thumb: some View {
        ZStack {
            Color.ofCode
            if let url = thumbURL {
                CachedAsyncImage(url: url, maxPixelSize: Metrics.thumbWidth * max(displayScale, 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { failed in
                    if failed && isPodcast { headphonesPlaceholder } else { Color.ofCode }
                }
            } else {
                headphonesPlaceholder
            }
            if isVideo {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .overlay(
                        OFIcon.play.image
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 0.5)
                    )
            }
        }
        .frame(width: Metrics.thumbWidth, height: Metrics.thumbHeight)
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
        .overlay(alignment: .bottomTrailing) {
            if (isVideo || isPodcast), let dur = TextFormat.duration(item.item.durationSec) {
                Text(dur)
                    .font(OFFont.thumbBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 14)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
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
