import OpenDispatchCore
import SwiftUI

/// The comments under a thread in the reader: a Reddit, X, Bluesky or Hacker News post's replies, a YouTube video's
/// comments, or (when asked, with "Show comments") the Hacker News discussion of an article. Read fresh each time the item
/// opens, through `AppModel.comments(for:)`.
///
/// Comments come flattened with their depth; a rail per level shows the nesting, and clicking a comment's author line folds
/// it with its replies. "N more replies" and "More comments" rows load the rest in place. A YouTube comment longer than
/// four lines is cut there with "Read more" under it. X's replies need the app signed in to X, so a signed-out reader shows
/// the sign-in note instead and loads once signed in.
struct ReaderComments: View {
    let url: String
    let place: DiscussionPlace
    /// Wait for "Show comments" before loading (an article whose discussion is elsewhere).
    var onDemand = false
    /// The comment count the item already knows, for the heading before they load.
    var count: Int?
    /// The hairline and "Comments" heading; a video's Comments tab has its own.
    var heading = true
    /// Told the thread's total once it loads (the video's tab shows it).
    var onTotal: (Int?) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var phase: Phase = .idle
    @State private var entries: [DiscussionEntry] = []
    @State private var total: Int?
    @State private var folded: Set<String> = []
    /// Long comments opened with "Read more".
    @State private var opened: Set<String> = []
    @State private var loadingMore: Set<String> = []
    @State private var failedMore: Set<String> = []

    private enum Phase: Equatable { case idle, loading, loaded, failed(String), signIn }

    /// The thread an item's comments come from: the item itself when it is a thread, else its Hacker News discussion.
    static func target(for item: FeedItem) -> (url: String, place: DiscussionPlace, onDemand: Bool)? {
        let url = item.item.url
        if let place = DiscussionPlace.thread(of: url) { return (url, place, false) }
        if let hn = item.item.hnCommentsUrl, DiscussionPlace.thread(of: hn) == .hackerNews { return (hn, .hackerNews, true) }
        return nil
    }

    private var shownCount: Int? { total ?? count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if heading {
                Rectangle().fill(Color.ofHairline).frame(height: 1)
                headingRow
            }
            content
        }
        .task(id: "\(url)#\(model.accounts.changes)") {
            if !onDemand || phase != .idle { await load() }
        }
    }

    private var headingRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(place == .youtube ? "Comments" : onDemand ? "Discussion on \(place.name)" : "Comments")
                .font(OFFont.ui(15, .semibold))
                .foregroundStyle(.ofInk)
                .accessibilityAddTraits(.isHeader)
            if let n = shownCount, n > 0 {
                Text(ExploreFormat.count(n))
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .monospacedDigit()
            }
            if phase == .loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if let link = URL(string: url) {
                Link(destination: link) {
                    HStack(spacing: 5) {
                        Text(place == .youtube ? "On YouTube" : "On \(place.name)")
                        OFIcon.external.image.font(.system(size: 11))
                    }
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofMuted)
                }
                .buttonStyle(.plain)
                .help("Open the thread in your browser")
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            Button { Task { await load() } } label: {
                HStack(spacing: 6) {
                    OFIcon.comment.image.font(.system(size: 13))
                    Text(shownCount.map { "Show \($0 == 1 ? "1 comment" : "\(ExploreFormat.count($0)) comments")" } ?? "Show comments")
                }
                .font(OFFont.ui(14, .medium))
                .foregroundStyle(.ofAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        case .loading:
            ExploreSkeleton(style: .rows)
                .padding(.bottom, 8)
        case .signIn:
            ExploreSignInNote(account: .x, what: "replies")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn\u{2019}t load the comments")
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.ofInk)
                Text(message)
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.plain)
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(.ofAccent)
                    .padding(.top, 2)
            }
            .padding(.bottom, 8)
        case .loaded:
            if entries.isEmpty {
                ExploreEmptyNote(text: "No comments yet")
                    .padding(.bottom, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { entry in
                        switch entry {
                        case .comment(let comment):
                            ReaderCommentRow(comment: comment, place: place, folded: folded.contains(comment.id), replies: replyCount(comment),
                                             opened: opened.contains(comment.id)) {
                                if folded.contains(comment.id) { folded.remove(comment.id) } else { folded.insert(comment.id) }
                            } open: {
                                if opened.contains(comment.id) { opened.remove(comment.id) } else { opened.insert(comment.id) }
                            }
                        case .more(let more):
                            ReaderMoreCommentsRow(more: more, loading: loadingMore.contains(more.id), failed: failedMore.contains(more.id)) {
                                Task { await loadMore(more) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The entries not under a folded comment.
    private var visible: [DiscussionEntry] {
        var out: [DiscussionEntry] = []
        var hiddenBelow: Int?
        for entry in entries {
            if let limit = hiddenBelow {
                if entry.depth > limit { continue }
                hiddenBelow = nil
            }
            out.append(entry)
            if case .comment(let c) = entry, folded.contains(c.id) { hiddenBelow = c.depth }
        }
        return out
    }

    /// How many replies a folded comment hides (loaded ones only).
    private func replyCount(_ comment: DiscussionComment) -> Int {
        guard folded.contains(comment.id), let i = entries.firstIndex(where: { $0.id == comment.id }) else { return 0 }
        return entries[(i + 1)...].prefix { $0.depth > comment.depth }.filter { $0.comment != nil }.count
    }

    // MARK: Loading

    private func load() async {
        if place == .x, !model.accounts.isSignedIn(.x) {
            // At launch the sign-ins aren't read yet; `changes` moves once they are, which loads again.
            phase = model.accounts.checked ? .signIn : .loading
            return
        }
        phase = .loading
        do {
            let thread = try await model.comments(for: url)
            guard !Task.isCancelled else { return }
            entries = thread.entries
            total = thread.total
            onTotal(thread.total)
            folded = []
            opened = []
            phase = .loaded
        } catch DiscussionError.signInRequired {
            phase = .signIn
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(HTTP.message(error))
        }
    }

    /// Puts what a "more" row stands for in its place; a row that brings nothing goes.
    private func loadMore(_ more: DiscussionMore) async {
        guard !loadingMore.contains(more.id) else { return }
        loadingMore.insert(more.id)
        failedMore.remove(more.id)
        defer { loadingMore.remove(more.id) }
        do {
            let loaded = try await model.moreComments(more, in: url)
            guard let i = entries.firstIndex(where: { $0.id == more.id }) else { return }
            let known = Set(entries.map(\.id))
            entries.replaceSubrange(i...i, with: loaded.filter { !known.contains($0.id) })
        } catch {
            failedMore.insert(more.id)
        }
    }
}

/// One comment: its author line (avatar, name, age, score) over its text, indented by a rail per level. Clicking the
/// author line folds it and its replies. A YouTube comment is cut to four lines with "Read more" under it; YouTube's
/// comments are plain text, so the cut version is one Text with the paragraphs a blank line apart. The text is set at the
/// feed row's size (`ReaderCommentType`), the author line like a feed row's meta line. In a narrow reader the type is
/// smaller and the author line wraps.
private struct ReaderCommentRow: View {
    let comment: DiscussionComment
    let place: DiscussionPlace
    let folded: Bool
    /// Replies hidden while folded.
    let replies: Int
    /// Opened with "Read more".
    let opened: Bool
    let toggle: () -> Void
    let open: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.readerNarrow) private var narrow
    @State private var cut = false

    private var type: ReaderCommentType { ReaderCommentType(settings: model.settings, narrow: narrow) }
    private var size: CGFloat { type.size }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ReaderCommentRails(depth: comment.depth, avatar: type.avatar)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 8) {
                Button(action: toggle) { header }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(comment.author), \(folded ? "folded" : "")")
                    .accessibilityHint(folded ? "Shows the comment" : "Folds the comment and its replies")
                if !folded {
                    if place == .youtube, !opened {
                        Text(clampedBody)
                            .font(OFFont.ui(size))
                            .lineSpacing(type.lineSpacing)
                            .foregroundStyle(.ofInk)
                            .tint(.ofAccent)
                            .textSelection(.enabled)
                            .readerClamped(4, truncated: $cut)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ReaderRichText(text: comment.body, size: size, lineSpacing: type.lineSpacing)
                    }
                    if place == .youtube, cut || opened {
                        ReaderDisclosureButton(title: opened ? "Show less" : "Read more", open: opened, size: type.meta, action: open)
                            .padding(.top, 1)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var clampedBody: AttributedString {
        var out = AttributedString()
        for (i, paragraph) in comment.body.paragraphs.enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            out += ReaderRichText.attributed(paragraph)
        }
        return out
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let avatar = comment.avatarUrl, let url = URL(string: avatar) {
                CachedAsyncImage(url: url, maxPixelSize: 72) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.ofCode
                }
                .frame(width: type.avatar, height: type.avatar)
                .clipShape(Circle())
                .accessibilityHidden(true)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let name = Text(verbatim: comment.author).fontWeight(.semibold)
                    .foregroundStyle(comment.byAuthor ? Color.ofAccent : Color.ofInk)
                var tail = ""
                if let date = comment.published { tail += " \u{00B7} " + RelativeTime.format(date, now: context.date) }
                if let score = comment.score, score > 0 || place == .reddit {
                    let unit = place == .reddit ? "point" : "like"
                    tail += " \u{00B7} \(ExploreFormat.count(score)) \(score == 1 ? unit : unit + "s")"
                }
                if folded { tail += replies > 0 ? " \u{00B7} \(replies) more" : " \u{00B7} folded" }
                return Text("\(name)\(Text(verbatim: tail).foregroundStyle(Color.ofMuted))")
                    .font(OFFont.ui(type.meta))
                    .lineLimit(narrow ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: narrow)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// "27 more replies" / "More comments", indented like the comments it stands for, muted with a chevron.
private struct ReaderMoreCommentsRow: View {
    let more: DiscussionMore
    let loading: Bool
    let failed: Bool
    let action: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.readerNarrow) private var narrow

    var body: some View {
        let type = ReaderCommentType(settings: model.settings, narrow: narrow)
        HStack(alignment: .center, spacing: 0) {
            ReaderCommentRails(depth: more.depth, avatar: type.avatar)
            if loading { ProgressView().controlSize(.small).padding(.trailing, 6) }
            ReaderDisclosureButton(title: label, size: type.meta, tint: failed ? .ofDanger : nil, action: action)
                .padding(.vertical, 10)
                .disabled(loading)
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        if failed { return "Couldn\u{2019}t load them. Try again" }
        let noun = more.depth == 0 ? "comments" : "replies"
        if let n = more.count, n > 0 { return "\(ExploreFormat.count(n)) more \(n == 1 ? String(noun.dropLast()) : noun)" }
        return "More \(noun)"
    }
}

/// The comments' type: the text at the sidebar and feed row size (14.5 on the Mac and iPad, 15 under the iPhone's 17pt
/// rows), fixed rather than following the reader's text size, so a thread of one-liners reads at the rail's size and not the
/// post's; the line spacing still follows the setting. The author line and the "Read more" / "More replies" rows are at the
/// feed row's meta size. A narrow reader takes a step down.
struct ReaderCommentType {
    let size: CGFloat
    let lineSpacing: CGFloat
    let meta: CGFloat
    let avatar: CGFloat

    init(settings: AppSettings, narrow: Bool) {
        #if os(iOS)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let phone = false
        #endif
        size = narrow ? 13.5 : phone ? 15 : 14.5
        meta = narrow ? 12 : phone ? 13.5 : 13
        lineSpacing = size * (settings.lineSpacing.lineHeight - 1.2)
        avatar = narrow ? 18 : 20
    }
}

/// A thin line per level of nesting, under the parent's avatar (at most eight, so deep threads keep their width).
private struct ReaderCommentRails: View {
    let depth: Int
    var avatar: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<min(depth, 8), id: \.self) { _ in
                Rectangle()
                    .fill(Color.ofHairline)
                    .frame(width: 1)
                    .padding(.leading, avatar / 2 - 0.5)
                    .padding(.trailing, avatar / 2 + 7.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// `RichText` as paragraphs: links in the accent color, bold and italic as written, quotes behind a bar, code blocks on a
/// tinted ground and list items with a bullet. Paragraphs are a blank line apart, as on X.
struct ReaderRichText: View {
    let text: RichText
    var size: CGFloat = 15
    var lineSpacing: CGFloat?

    private var leading: CGFloat { lineSpacing ?? size * 0.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.paragraphs.enumerated()), id: \.offset) { i, paragraph in
                Group {
                    switch paragraph.style {
                    case .plain:
                        line(paragraph)
                    case .quote:
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle().fill(Color.ofBorder).frame(width: 2)
                            line(paragraph).foregroundStyle(.ofMuted)
                        }
                    case .code:
                        line(paragraph)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.ofCode, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\u{2022}").foregroundStyle(.ofMuted)
                            line(paragraph)
                        }
                    }
                }
                .padding(.top, i == 0 ? 0 : gap(after: text.paragraphs[i - 1], before: paragraph))
            }
        }
    }

    /// A blank line between paragraphs; list items run on with only the line spacing between them.
    private func gap(after previous: RichText.Paragraph, before paragraph: RichText.Paragraph) -> CGFloat {
        previous.style == .bullet && paragraph.style == .bullet ? leading + size * 0.3 : size * 1.2 + 2 * leading
    }

    private func line(_ paragraph: RichText.Paragraph) -> some View {
        Text(Self.attributed(paragraph))
            .font(OFFont.ui(size))
            .lineSpacing(leading)
            .foregroundStyle(.ofInk)
            .tint(.ofAccent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Built as an NSAttributedString, as `ReaderText.linkified` is: links (drawn in the tint), bold and italic.
    static func attributed(_ paragraph: RichText.Paragraph) -> AttributedString {
        let out = NSMutableAttributedString()
        for run in paragraph.runs {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let link = run.link, let url = URL(string: link) { attributes[.link] = url }
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { attributes[.inlinePresentationIntent] = intent.rawValue }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return AttributedString(out)
    }
}
