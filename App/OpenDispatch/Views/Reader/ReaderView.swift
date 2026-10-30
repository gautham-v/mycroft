import OpenDispatchCore
import SwiftUI

/// Reading pane (port of src/components/reader.tsx): sticky toolbar (back on phones, source badge,
/// source · time, Save, Open original, a Share menu that also sends, then split and full screen on desktop), headline,
/// byline, article HTML in a height-fitted WKWebView styled by Resources/reader.css, a YouTube player
/// for videos and a native audio player for podcasts. Shows the empty state when nothing is selected.
///
/// On the desktop the reader is one pane or two side by side (ReaderSplitView), and each pane's bar
/// shows its tabs, even a lone one, with + for a new tab (ReaderTabs.swift).
///
/// On iPhone it is pushed in the list's NavigationStack and uses the system navigation bar (Liquid
/// Glass): the system back button pops (ItemListView's binding then calls `model.select(nil)`), the
/// actions sit in the bar, and the meta row (badge, source · time) scrolls with the article.
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isSplit {
                ReaderSplitView()
            } else {
                ReaderPaneView(pane: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ofSurface)
        #if os(macOS)
        .background { TabDragReset(active: model.tabDrag != nil) { model.tabDrag = nil } }
        #endif
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
    /// The pane showing it (split view has two).
    var pane = 0

    @Environment(AppModel.self) private var model
    @Environment(HighlightStore.self) private var highlights
    @Environment(\.openURL) private var openURL
    @Environment(ReaderSpeech.self) private var speech

    @Environment(\.displayScale) private var displayScale
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var content: ReaderContentState = .loading
    /// The article came back as the site's teaser only (`ExtractResult.paywalled`).
    @State private var paywalled = false
    /// Read aloud's hold on this article's web view.
    @State private var speechPage = ReaderSpeechPage()
    /// The reader's visible height under the toolbar, which sizes a Short's player (videos only).
    @State private var viewportHeight: CGFloat = 0

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
    /// Posts (X, Bluesky, Mastodon, LinkedIn, Threads, Instagram) have no headline: the extracted markup carries the author row, text and cards.
    private var isPost: Bool { TextFormat.isSocialPost(item.item.url) && content != .failed }
    private var itemURL: URL? { URL(string: item.item.url) }

    private var contentHTML: String? {
        if case .ok(let html, _, _) = content { return html }
        return nil
    }

    private var leadArt: String? {
        // A sharing crop is rewritten to the page's picture and the site's own card dropped (LeadImage.display).
        if let t = LeadImage.display(item.item.thumbnailUrl) { return t }
        if case .ok(_, let lead, _) = content { return LeadImage.display(lead) }
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

    /// A page whose video the site's own player loads (`SiteVideo`): the reader plays it above the blurb.
    private var isSiteVideo: Bool { SiteVideo.isMarked(contentHTML) }
    /// A story whose page leads with its audio (NPR's segments): played in the podcast player above the text.
    private var siteAudio: SiteAudio.Audio? { isPodcast ? nil : SiteAudio.audio(in: contentHTML) }

    /// The hero to draw above the body unless the content already leads with it (or a video).
    private var visibleHero: String? {
        guard let hero, !isSiteVideo else { return nil }
        if let html = bodyHTML, ReaderText.contentHasHero(html, hero: hero) { return nil }
        // A Reddit post's thumbnail is a small copy of the image its body already shows full size.
        if DiscussionPlace.thread(of: item.item.url) == .reddit, bodyHTML?.contains("<img") == true { return nil }
        return hero
    }

    /// The toolbar title, as the item's list row reads: source (or a post's author and handle) in
    /// ink, then " · 31m" muted, both at the sidebar's row size. Re-rendered every minute.
    private var titleLine: some View {
        let (author, handle) = TextFormat.isSocialPost(item.item.url) ? TextFormat.splitHandle(item.item.author) : ("", nil)
        let name = author.isEmpty ? item.originName : author
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            let lead = Text(verbatim: name).foregroundStyle(Color.ofInk)
            let tail = Text(verbatim: (handle.map { " @\($0)" } ?? "") + " · " + RelativeTime.format(item.item.publishedAt, now: context.date))
                .foregroundStyle(Color.ofMuted)
            Text("\(lead)\(tail)")
                .font(OFFont.readerToolbarTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var appearance: ReaderHTML.Appearance {
        ReaderHTML.Appearance(font: settings.readerFont, size: settings.textSize, leading: settings.lineSpacing,
                              theme: settings.theme, wide: wide,
                              columnWidth: settings.readerColumnWidth, links: settings.linkStyle,
                              themeCSS: settings.readerThemeCSS)
    }

    /// Listen (read aloud) works on anything with an extracted body.
    private var canListen: Bool { contentHTML != nil && !isVideo }

    /// Listen button and menu command: start reading, or pause / resume when already reading this article.
    private func listen() {
        guard canListen else { return }
        speech.toggle(page: speechPage, item: item, settings: settings)
    }

    private var listenLabel: String {
        speech.owns(speechPage) ? (speech.state == .playing ? "Pause reading" : "Resume reading") : "Listen"
    }

    private var buttonSize: CGFloat { compact ? Metrics.touchTarget : Metrics.readerActionButton }
    private var glyphSize: CGFloat { compact ? 17 : Metrics.readerActionGlyph }

    // MARK: Body

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    // A video's own header shows the source and date under the player, and a post's author row
                    // shows its author, age and network, so both skip this row.
                    if compact, !isVideo, !isPost {
                        metaRow
                            .readerColumn(wide: false)
                            .padding(.top, 8)
                    }
                    if isVideo {
                        ReaderVideoBody(item: item, autoplay: settings.autoplay && model.autoplayItemID == item.id, theater: settings.theater, wide: wide,
                                        viewportHeight: viewportHeight)
                    } else {
                        article
                        if settings.showComments, let thread = ReaderComments.target(for: item) {
                            ReaderComments(url: thread.url, place: thread.place, onDemand: thread.onDemand, count: item.item.hnComments)
                                .id(item.id)
                                .readerColumn(wide: wide)
                                .padding(.bottom, 40)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.readerScroll, proxy)
            }
        }
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.containerSize.height - geo.contentInsets.top - geo.contentInsets.bottom
        } action: { _, height in
            if isVideo { viewportHeight = height }
        }
        .overlayScrollers()
        .readerHighlights(item: item, pane: pane, compact: compact)
        // The article scrolls under the toolbar, which is frosted.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !compact { toolbar }
        }
        .background(Color.ofSurface)
        #if os(iOS)
        .toolbar { if compact { phoneToolbar } }
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .readerSpeech(page: speechPage, pane: pane, compact: compact, contentKey: bodyHTML, listen: listen)
        .onAppear {
            // Explicit captures: the page owns this closure, and capturing the view would keep its state
            // (the page itself and the article HTML) alive after the article closes.
            speechPage.onReadAloudFromSelection = { [weak speechPage, speech, model, item] in
                guard let speechPage else { return }
                speech.toggle(page: speechPage, item: item, settings: model.settings, from: .selection)
            }
        }
        .task { await load(refresh: false) }
        // Reload Article (⇧⌘R, or the article's right-click menu).
        .onChange(of: model.articleReloads[item.id]) { _, _ in Task { await load(refresh: true) } }
        // Done on the site's sign-in sheet: the teaser loads again as you.
        .onChange(of: model.accounts.siteSignIns[Paywalls.site(of: item.item.url)]) { _, _ in
            if paywalled { Task { await load(refresh: true) } }
        }
    }

    /// Source badge + source · time, as in the item's list row.
    private var metaRow: some View {
        HStack(spacing: 8) {
            SourceBadge(host: item.source.host, title: item.originName, size: 20)
            titleLine
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
            if canListen {
                Button(action: listen) {
                    Label(listenLabel, systemImage: OFIcon.headphones.rawValue)
                }
                .tint(speech.owns(speechPage) ? Color.ofAccent : Color.primary)
            }
            if !isVideo {
                Button { highlights.isSheetPresented.toggle() } label: {
                    Label("Highlights & Notes", systemImage: OFIcon.highlighter.rawValue)
                }
                .tint(highlights.isSheetPresented ? Color.ofAccent : Color.primary)
            }
            if let url = itemURL {
                Button { openURL(url) } label: {
                    Label("Open original", systemImage: OFIcon.external.rawValue)
                }
                .tint(Color.primary)
                Button {
                    ItemShareSheet.present(url: url, title: item.item.title) { model.copyMarkdown(item: item) }
                } label: {
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

    /// macOS / iPad toolbar row: the pane's tabs, then the actions (iPhone uses the system bar, see
    /// `phoneToolbar`).
    private var toolbar: some View {
        ReaderBar(pane: pane) { actions }
    }

    private var actions: some View {
        HStack(spacing: compact ? 0 : Metrics.readerActionSpacing) {
            Button {
                Task { await model.toggleSaved(item) }
            } label: {
                if item.isSaved {
                    OFIcon.bookmarkFilled.image.foregroundStyle(Color.ofAccent)
                } else {
                    OFIcon.bookmark.image
                }
            }
            .buttonStyle(ReaderIconButtonStyle(size: buttonSize, glyph: glyphSize))
            .help(item.isSaved ? "Remove from saved" : "Save")
            .accessibilityLabel(item.isSaved ? "Remove from saved" : "Save")

            if canListen {
                Button(action: listen) {
                    OFIcon.headphones.image.foregroundStyle(speech.owns(speechPage) ? Color.ofAccent : Color.ofInk)
                }
                .buttonStyle(ReaderIconButtonStyle(size: buttonSize, glyph: glyphSize))
                .help(speech.owns(speechPage) ? "Pause or resume reading (⇧⌘L)" : "Listen (⇧⌘L)")
                .accessibilityLabel(listenLabel)
            }
            if !isVideo {
                HighlightsToolbarButton(item: item, pane: pane, compact: compact, size: buttonSize, glyph: glyphSize)
            }

            // Open Original, Share…, Copy, Send to and Reload Article in one menu.
            SendToView(item: item, size: buttonSize, iconSize: glyphSize, more: true, link: itemURL)

            if !compact {
                // Article actions on the left, window controls on the right.
                Rectangle().fill(Color.ofHairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 6)

                if model.isSplit {
                    Button { model.closePane(pane) } label: { OFIcon.close.image }
                        .buttonStyle(ReaderIconButtonStyle(size: buttonSize, glyph: glyphSize))
                        .help("Close this pane")
                        .accessibilityLabel("Close pane")
                } else {
                    Button { model.toggleSplit() } label: { OFIcon.split.image }
                        .buttonStyle(ReaderIconButtonStyle(size: buttonSize, glyph: glyphSize))
                        .help("Split view (⌥⌘S)")
                        .accessibilityLabel("Split view")
                }

                // One full-screen button per window: the right pane's in split view.
                if !model.isSplit || pane == model.panes.count - 1 {
                    Button { model.toggleFocusMode() } label: {
                        (model.isFocused ? OFIcon.collapse : OFIcon.expand).image
                    }
                    .buttonStyle(ReaderIconButtonStyle(size: buttonSize, glyph: glyphSize))
                    .help(model.isFocused ? "Exit full screen (esc)" : "Full screen (⇧⌘F)")
                    .accessibilityLabel(model.isFocused ? "Exit full screen" : "Full screen")
                }
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
                VStack(spacing: 0) {
                    if isSiteVideo, let page = itemURL {
                        ReaderSiteVideo(page: page, poster: hero, title: item.item.title)
                            .id(item.id)
                            .readerColumn(wide: wide)
                            .padding(.bottom, 24)
                    }
                    ReaderArticleWebView(html: bodyHTML ?? "", hero: visibleHero, baseURL: itemURL, appearance: appearance,
                                         post: isPost ? ReaderHTML.Post(published: item.item.publishedAt, host: itemURL?.host) : nil,
                                         onReload: { model.reloadArticle(item) },
                                         onCopyMarkdown: { model.copyMarkdown(item: item) }, speechPage: speechPage)
                }
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
        .padding(.top, isPost ? (wide ? 40 : 36) : 28)

        if paywalled, !isPost, case .ok = content {
            ReaderPaywallBanner(item: item)
                .readerColumn(wide: wide)
                .padding(.bottom, 32)
        }
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
                Text(item.originName).fontWeight(.medium).foregroundStyle(.ofInk)
                if let author = item.item.author, !author.isEmpty, author != item.originName {
                    Text(author)
                }
                // The bar shows tabs, not source · time, so the age lives here (phones have the meta row).
                if wide {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let age = RelativeTime.format(item.item.publishedAt, now: context.date)
                        Text(age == "now" ? "just now" : "\(age) ago")
                    }
                }
                if isPodcast, let dur = TextFormat.duration(item.item.durationSec) {
                    Text(dur).monospacedDigit()
                }
                if settings.showComments, let comments = item.item.hnCommentsUrl, let url = URL(string: comments) {
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
                ReaderPodcastPlayer(item: item, art: podcastArt, wide: wide, resumeAt: model.history.resumePosition(item))
                    .id(item.id)
                    .padding(.top, 24)
            } else if let siteAudio {
                ReaderPodcastPlayer(item: item, art: nil, wide: wide, resumeAt: model.history.resumePosition(item), audio: siteAudio)
                    .id("\(item.id)-\(siteAudio.url)")
                    .padding(.top, 24)
            }
        }
    }

    private var headlineText: some View {
        Text(item.item.title)
            .font(OFFont.reader(settings.readerFont, headlineSize, .semibold))
            .tracking(-0.01 * headlineSize)
            .foregroundStyle(.ofInk)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same items the article body's right-click menu adds (ReaderFittedWebView).
    @ViewBuilder private var headlineMenu: some View {
        if let url = itemURL {
            Button("Open Original") { openURL(url) }
            Button("Copy Link") { ReaderPasteboard.copy(url) }
        }
        Button("Copy as Markdown") { model.copyMarkdown(item: item) }
        Divider()
        Button("Reload Article") { model.reloadArticle(item) }
            .disabled(content == .loading)
    }

    /// Shown while the article loads and when extraction failed (the web view draws its own). Through
    /// `CachedAsyncImage` so it is decoded off the main thread at the column's size; `AsyncImage`
    /// decoded the full-size original on the main thread as each article opened.
    @ViewBuilder private var heroImage: some View {
        if let hero = visibleHero, let url = URL(string: hero) {
            CachedAsyncImage(url: url, maxPixelSize: (settings.readerColumnWidth ?? 1200) * max(displayScale, 2)) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
            } placeholder: { _ in
                EmptyView()
            }
        }
    }

    private var failure: some View {
        let summary = TextFormat.stripHTML(item.item.summary)
        return VStack(alignment: .leading, spacing: 0) {
            heroImage
            if !summary.isEmpty {
                Text(summary)
                    .font(OFFont.reader(settings.readerFont, OFFont.bodySize(settings.textSize)))
                    .lineSpacing(OFFont.bodySize(settings.textSize) * (settings.lineSpacing.lineHeight - 1.2))
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
                paywalled = result.paywalled
                content = .ok(html: html, leadImage: result.leadImage, rendered: result.rendered)
            } else {
                paywalled = false
                content = .failed
            }
        } catch {
            guard !Task.isCancelled else { return }
            paywalled = false
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
    let model = AppModel.preview()
    return ReaderView().environment(model).environment(HighlightStore(model: model)).environment(ReaderSpeech())
}
