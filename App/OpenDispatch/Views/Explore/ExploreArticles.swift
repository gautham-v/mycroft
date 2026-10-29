import OpenDispatchCore
import SwiftUI

/// A news article in Explore's results, shared by the New Tab page (Mac, iPad) and the iPhone's Explore page: the outlet's
/// favicon, "Outlet · 3h" (ending in the paywall mark, a lock and "Subscribers" or "May need sign-in", as the lists mark), the
/// headline, a line of its summary and its picture. It opens in the reader as an opened link.
struct ExploreArticleRow: View {
    let article: ExploreArticle
    var isPhone = false
    /// How the article's site stands (`AppModel.paywallStatus(of:)`); `.free` for no mark.
    var paywall: PaywallStatus = .free
    let isOpening: Bool
    /// Opens it; true for a new tab.
    let open: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var avatarSize: CGFloat { isPhone ? 32 : 28 }
    private var host: String { URLHost.host(of: article.url) }

    /// The summary when it says more than the headline.
    private var summary: String? {
        guard let s = article.summary, !s.isEmpty, s.caseInsensitiveCompare(article.title) != .orderedSame,
              !s.lowercased().hasPrefix(article.title.lowercased()) else { return nil }
        return s
    }

    var body: some View {
        Button { open(false) } label: {
            HStack(alignment: .top, spacing: 10) {
                SourceBadge(host: host, title: article.outlet ?? host, size: avatarSize)
                VStack(alignment: .leading, spacing: 3) {
                    meta
                    Text(article.title)
                        .font(OFFont.ui(isPhone ? 15 : 13.5, .medium))
                        .foregroundStyle(paywall.markLabel != nil && !hovering ? Color.ofBody : hovering ? Color.ofAccent : Color.ofInk)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary {
                        Text(summary)
                            .font(OFFont.ui(isPhone ? 13 : 12))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOpening {
                    ProgressView().controlSize(.small).frame(width: 24)
                } else if let image = article.imageUrl, let url = URL(string: image) {
                    CachedAsyncImage(url: url, maxPixelSize: 220) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { _ in
                        Color.ofCode
                    }
                    .frame(width: isPhone ? 64 : 72, height: isPhone ? 64 : 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, isPhone ? 0 : 8)
            .padding(.vertical, isPhone ? 9 : 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering && !isPhone ? Color.ofHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { open(true) }
            if let url = URL(string: article.url) {
                Button("Open in Browser") { openURL(url) }
                Button("Copy Link") { ReaderPasteboard.copy(url) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([article.title, ExploreFormat.articleMeta(article), paywall.markLabel].compactMap { $0 }.joined(separator: ", "))
    }

    private var meta: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let lead = Text(verbatim: article.outlet ?? host).fontWeight(.medium).foregroundStyle(Color.ofInk)
            let age = Text(verbatim: " \u{00B7} " + RelativeTime.format(article.published, now: context.date)).foregroundStyle(Color.ofMuted)
            var line = Text("\(lead)\(age)")
            if let mark = paywall.markText { line = Text("\(line)\(Text(verbatim: " \u{00B7} ").foregroundStyle(Color.ofMuted))\(mark.foregroundStyle(Color.ofMuted))") }
            return line
                .font(OFFont.ui(isPhone ? 13 : 12))
                .lineLimit(1)
        }
    }
}

extension ExploreFormat {
    /// "The Guardian · 3h".
    static func articleMeta(_ article: ExploreArticle) -> String {
        [article.outlet ?? URLHost.host(of: article.url), RelativeTime.format(article.published)].joined(separator: " \u{00B7} ")
    }
}
