import OpenfeedCore
import SwiftUI

/// Reading pane (port of src/components/reader.tsx): sticky toolbar (back on phones, source badge,
/// host · date · read time, Save, Open original, Share, Send to, full screen on desktop), headline,
/// byline, article HTML in a height-fitted WKWebView styled by Resources/reader.css, a YouTube player
/// for videos and a native audio player for podcasts. Shows the empty state when nothing is selected.
///
/// On iPhone it is pushed in the list's NavigationStack and uses the system navigation bar (Liquid
/// Glass): the system back button pops (ItemListView's binding then calls `model.select(nil)`), the
/// actions sit in the bar, and the meta row (badge, host · date · read time) scrolls with the article.
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let item = model.selectedItem {
                ReaderItemView(item: item)
                    .id(item.id)
            } else {
                ReaderEmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ofSurface)
    }
}

/// "Nothing selected" (ReaderEmpty).
struct ReaderEmptyView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Nothing selected").font(OFFont.ui(15, .medium)).foregroundStyle(.ofInk)
            Text("Pick an item from the list").font(OFFont.ui(13)).foregroundStyle(.ofMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ofSurface)
    }
}

/// Article body state (useContent in reader.tsx).
enum ReaderContentState: Equatable {
    case loading
    case ok(html: String, leadImage: String?, rendered: Bool)
    case failed
}

struct ReaderItemView: View {
    let item: FeedItem

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var content: ReaderContentState = .loading

    // MARK: Derived (same rules as reader.tsx)

    /// Phone layout (below md in the web app).
    private var compact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var wide: Bool { !compact }
    private var settings: AppSettings { model.settings }
    private var isVideo: Bool { item.source.kind == .youtube }
    /// Podcasts read like articles with an audio player between header and notes.
    private var isPodcast: Bool { item.source.kind == .podcast && item.item.audioUrl != nil }
    /// Posts on X have no headline: the extracted markup carries the author row, text and cards.
    private var isPost: Bool { TextFormat.isXPost(item.item.url) && content != .failed }
    private var host: String {
        let h = URLHost.host(of: item.item.url)
        return h.isEmpty ? item.source.host : h
    }
    private var itemURL: URL? { URL(string: item.item.url) }

    private var contentHTML: String? {
        if case .ok(let html, _, _) = content { return html }
        return nil
    }

    private var leadArt: String? {
        if let t = item.item.thumbnailUrl, !t.isEmpty { return t }
        if case .ok(_, let lead, _) = content { return lead }
        return nil
    }

    /// A podcast's art sits beside its player, so it is never also the hero.
    private var hero: String? { !isVideo && !isPost && !isPodcast ? leadArt : nil }
    private var podcastArt: String? { isPodcast ? leadArt : nil }

    /// Show notes often open with the same art; drop it so it does not appear twice.
    private var bodyHTML: String? {
        guard let html = contentHTML else { return nil }
        if let art = podcastArt { return ReaderText.stripImage(html, src: art) }
        return html
    }

    /// The hero to draw above the body unless the content already leads with it (or a video).
    private var visibleHero: String? {
        guard let hero else { return nil }
        if let html = bodyHTML, ReaderText.contentHasHero(html, hero: hero) { return nil }
        return hero
    }

    private var metaLine: String {
        var parts = [host, TextFormat.date(item.item.publishedAt)]
        if !isVideo, let html = contentHTML { parts.append(ReaderText.readTime(html)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var appearance: ReaderHTML.Appearance {
        ReaderHTML.Appearance(font: settings.readerFont, size: settings.textSize, theme: settings.theme, wide: wide)
    }

    private var buttonSize: CGFloat { compact ? Metrics.touchTarget : Metrics.desktopIconButton }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if !compact { toolbar }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if compact {
                        metaRow
                            .readerColumn(wide: false)
                            .padding(.top, 8)
                    }
                    if isVideo {
                        ReaderVideoBody(item: item, autoplay: settings.autoplay, theater: settings.theater, wide: wide)
                    } else {
                        article
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.ofSurface)
        #if os(iOS)
        .toolbar { if compact { phoneToolbar } }
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load(refresh: false) }
    }

    /// Source badge + host · date · read time.
    private var metaRow: some View {
        HStack(spacing: 8) {
            SourceBadge(host: item.source.host, title: item.source.title, size: 20)
            Text(metaLine)
                .font(OFFont.readerToolbarMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    /// iPhone: Save, Open original, Share and Send to in the system bar (it groups them in glass).
    @ToolbarContentBuilder private var phoneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await model.toggleSaved(item) }
            } label: {
                Label(item.isSaved ? "Remove from saved" : "Save",
                      systemImage: (item.isSaved ? OFIcon.bookmarkFilled : OFIcon.bookmark).rawValue)
            }
            .tint(item.isSaved ? Color.ofAccent : Color.primary)
            if let url = itemURL {
                Button { openURL(url) } label: {
                    Label("Open original", systemImage: OFIcon.external.rawValue)
                }
                .tint(Color.primary)
                ShareLink(item: url, subject: Text(item.item.title), message: Text(item.item.title)) {
                    Label("Share", systemImage: OFIcon.share.rawValue)
                }
                .tint(Color.primary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            SendToView(item: item, size: 36, iconSize: 17, inSystemToolbar: true)
        }
    }
    #endif

    // MARK: Toolbar

    /// macOS / iPad toolbar row (iPhone uses the system bar, see `phoneToolbar`).
    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                SourceBadge(host: item.source.host, title: item.source.title, size: 20)
                Text(metaLine)
                    .font(OFFont.readerToolbarMeta)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.desktopHeaderHeight)
        .background(Color.ofSurface.opacity(0.95))
    }

    private var actions: some View {
        HStack(spacing: compact ? 0 : 2) {
            Button {
                Task { await model.toggleSaved(item) }
            } label: {
                (item.isSaved ? OFIcon.bookmarkFilled : OFIcon.bookmark).image
                    .foregroundStyle(item.isSaved ? AnyShapeStyle(Color.ofAccent) : AnyShapeStyle(.foreground))
            }
            .buttonStyle(ReaderIconButtonStyle(size: buttonSize))
            .help(item.isSaved ? "Remove from saved" : "Save")
            .accessibilityLabel(item.isSaved ? "Remove from saved" : "Save")

            if let url = itemURL {
                Button { openURL(url) } label: { OFIcon.external.image }
                    .buttonStyle(ReaderIconButtonStyle(size: buttonSize))
                    .help("Open original")
                    .accessibilityLabel("Open original")

                ShareLink(item: url, subject: Text(item.item.title), message: Text(item.item.title)) {
                    OFIcon.share.image
                }
                .buttonStyle(ReaderIconButtonStyle(size: buttonSize))
                .help("Share")
                .accessibilityLabel("Share")
            }

            SendToView(item: item, size: buttonSize, iconSize: 17)

            if !compact {
                Button { model.toggleFocusMode() } label: {
                    (model.isFocused ? OFIcon.collapse : OFIcon.expand).image
                }
                .buttonStyle(ReaderIconButtonStyle(size: buttonSize))
                .help(model.isFocused ? "Exit full screen (esc)" : "Full screen (⇧⌘F)")
                .accessibilityLabel(model.isFocused ? "Exit full screen" : "Full screen")
            }
        }
    }

    // MARK: Article

    @ViewBuilder private var article: some View {
        if !isPost {
            header
                .readerColumn(wide: wide)
                .padding(.top, wide ? 40 : 32)
        }

        Group {
            switch content {
            case .ok:
                ReaderArticleWebView(html: bodyHTML ?? "", hero: visibleHero, baseURL: itemURL, appearance: appearance)
            case .loading:
                VStack(alignment: .leading, spacing: 0) {
                    heroImage
                    ReaderSkeleton()
                }
                .readerColumn(wide: wide)
                .padding(.bottom, 32)
            case .failed:
                failure
                    .readerColumn(wide: wide)
                    .padding(.bottom, 32)
            }
        }
        .padding(.top, isPost ? (wide ? 32 : 24) : 28)
    }

    private var headlineSize: CGFloat { OFFont.headlineSize(settings.textSize, wide: wide) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let url = itemURL {
                    Link(destination: url) { headlineText }
                        .buttonStyle(.plain)
                } else {
                    headlineText
                }
            }
            .contextMenu { headlineMenu }

            ReaderFlowLayout(spacingX: 14, spacingY: 4) {
                Text(item.source.title).fontWeight(.medium).foregroundStyle(.ofInk)
                if let author = item.item.author, !author.isEmpty, author != item.source.title {
                    Text(author)
                }
                if isPodcast, let dur = TextFormat.duration(item.item.durationSec) {
                    Text(dur).monospacedDigit()
                }
                if let comments = item.item.hnCommentsUrl, let url = URL(string: comments) {
                    Button { openURL(url) } label: {
                        HStack(spacing: 4) {
                            OFIcon.comment.image.font(.system(size: 13))
                            Text("Discussion")
                        }
                        .foregroundStyle(.ofAccent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.item.hnComments.map { "\($0) comments" } ?? "Discussion")
                }
            }
            .font(OFFont.readerByline)
            .foregroundStyle(.ofMuted)
            .padding(.top, 14)

            if case .ok(_, _, true) = content {
                Text("Rendered copy")
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
                    .padding(.top, 6)
            }

            if isPodcast {
                ReaderPodcastPlayer(item: item, art: podcastArt, wide: wide)
                    .id(item.id)
                    .padding(.top, 24)
            }
        }
    }

    private var headlineText: some View {
        let font: Font = settings.readerFont == .sans
            ? OFFont.ui(headlineSize, .semibold)
            : OFFont.serif(headlineSize, .semibold)
        return Text(item.item.title)
            .font(font)
            .tracking(-0.01 * headlineSize)
            .foregroundStyle(.ofInk)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var headlineMenu: some View {
        if let url = itemURL {
            Button("Open original") { openURL(url) }
            Button("Copy link") { ReaderPasteboard.copy(url) }
        }
        Button("Retry extraction") { Task { await load(refresh: true) } }
            .disabled(content == .loading)
    }

    @ViewBuilder private var heroImage: some View {
        if let hero = visibleHero, let url = URL(string: hero) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private var failure: some View {
        let summary = TextFormat.stripHTML(item.item.summary)
        return VStack(alignment: .leading, spacing: 0) {
            heroImage
            if !summary.isEmpty {
                Text(summary)
                    .font(settings.readerFont == .sans ? OFFont.ui(OFFont.bodySize(settings.textSize))
                                                       : OFFont.serif(OFFont.bodySize(settings.textSize)))
                    .lineSpacing(OFFont.bodySize(settings.textSize) * 0.4)
                    .foregroundStyle(.ofInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 19)
            }
            HStack(spacing: 10) {
                if let url = itemURL {
                    Button { openURL(url) } label: {
                        HStack(spacing: 8) {
                            Text("Open original")
                            OFIcon.external.image.font(.system(size: 15))
                        }
                        .font(OFFont.ui(15, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Color.ofAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { Task { await load(refresh: true) } } label: {
                    HStack(spacing: 8) {
                        OFIcon.refresh.image.font(.system(size: 14))
                        Text("Retry extraction")
                    }
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ofBorder))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 24)
        }
    }

    // MARK: Loading

    /// Loads the body through ContentService (cached content_html, else extraction). `refresh` forces
    /// a fresh extraction (the web's `?refresh=1`). YouTube items have no body.
    private func load(refresh: Bool) async {
        guard !isVideo else { return }
        if refresh || content != .loading { content = .loading }
        do {
            let result = try await model.content(for: item, refresh: refresh)
            guard !Task.isCancelled else { return }
            if let html = result.contentHtml, !html.isEmpty {
                content = .ok(html: html, leadImage: result.leadImage, rendered: result.rendered)
            } else {
                content = .failed
            }
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed
        }
    }
}

/// Pulsing placeholder lines while the article loads.
struct ReaderSkeleton: View {
    private static let widths: [CGFloat] = [1, 0.96, 0.88, 1, 0.72, 0, 1, 0.92, 0.6]
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, w in
                if w > 0 {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.ofCode)
                            .frame(width: geo.size.width * w, height: 16)
                    }
                    .frame(height: 16)
                } else {
                    Color.clear.frame(height: 12)
                }
            }
        }
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityElement()
        .accessibilityLabel("Loading article")
    }
}

#Preview {
    ReaderView().environment(AppModel.preview())
}
