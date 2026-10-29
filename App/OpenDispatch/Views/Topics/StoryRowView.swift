import OpenDispatchCore
import SwiftUI

/// A topic's list row for a news story: the lead article with the other outlets that covered it and the story's Hacker News
/// thread behind it (`FeedItem.story`). Same bones as `ItemRowView` (meta line, headline, thumbnail on the right), but the
/// meta line shows a stack of up to three overlapping favicons and the outlets' names, a "+N" when there are more, then the
/// age of the newest coverage; "+N" opens the list of every outlet's own headline in place, and a chip under the headline
/// gives the thread's points and comments. Tapping the row opens the lead; each outlet and the chip open their own page.
///
/// The row is not a Button: its parts are. `onTapGesture` on the whole row is the lead, and the inner buttons take their own
/// clicks first. The closures (`StoryRowActions`) carry whatever the list needs for modifier keys and are not part of `==`.
/// iPhone (`isPhone`) puts the headline first and the meta line under it, like `ItemRowView`.
struct StoryRowView: View, Equatable {
    let item: FeedItem
    var isSelected = false
    var isSecondary = false
    var isOpenInTab = false
    var isHovered = false
    var isPhone = false
    var isRead = false
    var actions = StoryRowActions()

    /// The closures are left out: the list builds them afresh and they do the same thing.
    nonisolated static func == (a: StoryRowView, b: StoryRowView) -> Bool {
        a.item == b.item && a.isSelected == b.isSelected && a.isSecondary == b.isSecondary && a.isOpenInTab == b.isOpenInTab
            && a.isHovered == b.isHovered && a.isPhone == b.isPhone && a.isRead == b.isRead
    }

    var body: some View {
        StoryRowContent(item: item, isSelected: isSelected, isSecondary: isSecondary, isOpenInTab: isOpenInTab,
                        isHovered: isHovered, isPhone: isPhone, isRead: isRead, actions: actions)
    }
}

/// What a story row's parts do.
struct StoryRowActions {
    /// Open the lead article.
    var openLead: () -> Void = {}
    /// Open another outlet's article (the lead's own entry in the list opens the lead).
    var openOutlet: (TopicOutlet) -> Void = { _ in }
    /// Open the Hacker News thread.
    var openDiscussion: () -> Void = {}
}

/// The row's drawing, which holds the expanded state of "+N".
private struct StoryRowContent: View {
    let item: FeedItem
    let isSelected: Bool
    let isSecondary: Bool
    let isOpenInTab: Bool
    let isHovered: Bool
    let isPhone: Bool
    let isRead: Bool
    let actions: StoryRowActions

    @State private var expanded = false

    private var story: TopicStory { item.story ?? TopicStory(outlets: []) }
    private var outlets: [TopicOutlet] { story.outlets }
    /// The newest coverage, which is where the row sorts.
    private var newest: Date { item.item.storyAt ?? item.item.publishedAt }
    private var titleColor: Color { isRead ? .ofRead : .ofInk }
    private var shownOutlets: [TopicOutlet] { Array(outlets.prefix(StoryOutletStack.limit)) }
    private var extra: Int { max(0, outlets.count - StoryOutletStack.limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: isPhone ? 8 : 6) {
            if isPhone { phoneMain } else { main }
            if expanded && outlets.count > 1 {
                StoryOutletList(outlets: outlets, open: pick)
            }
            if let discussion = story.discussion {
                DiscussionChip(discussion: discussion, action: actions.openDiscussion)
            }
        }
        .itemRowChrome(isSelected: isSelected, isSecondary: isSecondary, isHovered: isHovered, isPhone: isPhone)
        .onTapGesture(perform: actions.openLead)
        .accessibilityElement(children: .contain)
    }

    /// An outlet in the expanded list: the lead's own opens the lead.
    private func pick(_ outlet: TopicOutlet) {
        if outlet.id == item.id { actions.openLead() } else { actions.openOutlet(outlet) }
    }

    // MARK: Layouts

    private var main: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaLine
            HStack(alignment: .top, spacing: 12) {
                title(OFFont.itemTitle, tracking: -0.07)
                thumbnail(.compact)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, actions.openLead)
    }

    private var phoneMain: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                title(OFFont.phoneItemTitle, tracking: -0.3, lines: 3)
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            thumbnail(.square)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, actions.openLead)
    }

    private func title(_ font: Font, tracking: CGFloat, lines: Int? = nil) -> some View {
        Text(item.item.title)
            .font(isRead && isPhone ? OFFont.phonePostText : font)
            .tracking(tracking)
            .lineSpacing(2)
            .foregroundStyle(titleColor)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func thumbnail(_ style: ItemThumbnail.Style) -> some View {
        ItemThumbnail(item: item, style: style)
            .opacity(isRead ? 0.55 : 1)
    }

    /// The favicon stack, the outlets' names (truncating), "+N" and the age.
    private var metaLine: some View {
        HStack(spacing: 6) {
            StoryOutletStack(outlets: shownOutlets)
                .opacity(isRead ? 0.6 : 1)
            Text(verbatim: shownOutlets.map(\.name).joined(separator: ", "))
                .font(metaFont)
                .foregroundStyle(Color.ofMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            if extra > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Text(verbatim: expanded ? "less" : "+\(extra)")
                        .font(metaFont)
                        .foregroundStyle(Color.ofAccent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(expanded ? "Hide outlets" : "Show \(extra) more outlets")
            }
            Text(verbatim: "\u{00B7} " + RelativeTime.format(newest))
                .font(metaFont)
                .foregroundStyle(Color.ofMuted)
                .lineLimit(1)
                .fixedSize()
            if isOpenInTab && !isPhone {
                Spacer(minLength: 0)
                Circle()
                    .fill(Color.ofAccent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var metaFont: Font { isPhone ? OFFont.phoneItemMeta : OFFont.itemMeta }

    private var accessibilityText: String {
        var parts = [item.item.title, outlets.map(\.name).joined(separator: ", "), RelativeTime.format(newest)]
        if let discussion = story.discussion {
            parts.append("\(DiscussionStats.pointsText(discussion.points)), \(DiscussionStats.commentsText(discussion.comments)) on Hacker News")
        }
        if item.isSaved { parts.append("Saved") }
        if isRead { parts.append("Read") }
        if isOpenInTab { parts.append("Open in a tab") }
        return parts.joined(separator: ", ")
    }
}

/// Up to three outlets' favicons overlapping, the first on top of the rest's left edge.
struct StoryOutletStack: View {
    let outlets: [TopicOutlet]

    /// How many favicons (and names) the meta line shows before "+N".
    static let limit = 3
    private static let size: CGFloat = 16

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(outlets.enumerated()), id: \.element.id) { index, outlet in
                SourceBadge(host: outlet.host, title: outlet.name, size: Self.size)
                    .overlay(
                        RoundedRectangle(cornerRadius: (Self.size * 0.29).rounded(), style: .continuous)
                            .strokeBorder(Color.ofSurface, lineWidth: 1.5)
                    )
                    .zIndex(Double(outlets.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Every outlet of a story, expanded under its meta line: favicon, that outlet's headline and its name. Each opens its article.
struct StoryOutletList: View {
    let outlets: [TopicOutlet]
    let open: (TopicOutlet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(outlets) { outlet in
                StoryOutletRow(outlet: outlet) { open(outlet) }
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StoryOutletRow: View {
    let outlet: TopicOutlet
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SourceBadge(host: outlet.host, title: outlet.name, size: 14)
                Text(verbatim: outlet.title)
                    .font(OFFont.ui(13))
                    .foregroundStyle(Color.ofInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: outlet.name)
                    .font(OFFont.ui(12))
                    .foregroundStyle(Color.ofMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(hovered ? Color.ofHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(outlet.title), \(outlet.name)")
    }
}

/// "▲ 10 points · 4 comments on Hacker News" under a story's headline; opens the thread in the reader.
struct DiscussionChip: View {
    let discussion: TopicDiscussion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DiscussionStats.orange)
                Text(verbatim: "\(DiscussionStats.pointsText(discussion.points)) \u{00B7} \(DiscussionStats.commentsText(discussion.comments)) on Hacker News")
                    .font(OFFont.ui(12))
                    .foregroundStyle(Color.ofInk.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.ofCode, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DiscussionStats.pointsText(discussion.points)), \(DiscussionStats.commentsText(discussion.comments)) on Hacker News")
        .accessibilityHint("Opens the discussion")
    }
}

/// A discussion row's numbers: "· ▲ 15 · 💬 4" at the end of the meta line, drawn with SF Symbols.
enum DiscussionStats {
    /// Hacker News's orange.
    static let orange = Color(hexString: "FF6600")

    static func pointsText(_ points: Int) -> String { points == 1 ? "1 point" : "\(points) points" }
    static func commentsText(_ comments: Int) -> String { comments == 1 ? "1 comment" : "\(comments) comments" }

    /// The points and comments of a Hacker News or Reddit row of a topic (whichever it has), as meta-line text; nil for any other row.
    static func text(item: Item, isTopicItem: Bool) -> Text? {
        guard isTopicItem, item.hnPoints != nil || item.hnComments != nil else { return nil }
        let points = item.hnPoints.map { Text("\(Text(Image(systemName: "arrowtriangle.up.fill")).font(.system(size: 8)))\(Text(verbatim: " \($0)"))") }
        let comments = item.hnComments.map { Text("\(Text(Image(systemName: "bubble.left")).font(.system(size: 10)))\(Text(verbatim: " \($0)"))") }
        switch (points, comments) {
        case let (p?, c?): return Text("\(p)\(Text(verbatim: " \u{00B7} "))\(c)")
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    /// The same for VoiceOver.
    static func spoken(item: Item, isTopicItem: Bool) -> String? {
        guard isTopicItem, item.hnPoints != nil || item.hnComments != nil else { return nil }
        return [item.hnPoints.map(pointsText), item.hnComments.map(commentsText)].compactMap { $0 }.joined(separator: ", ")
    }
}

#Preview("Story row") {
    let topic = Source(id: 1, title: "Firefox", url: "https://opendispatch.app/topics", feedUrl: "opendispatch:topic:preview", kind: .topic, group: "topics")
    let now = Date()
    let lead = Item(id: 1, sourceId: 1, guid: "a", url: "https://news.yahoo.com/a", title: "Firefox reunites 2000s meme stars for an anti-AI ad",
                    author: "Yahoo", publishedAt: now.addingTimeInterval(-18 * 3_600), storyAt: now.addingTimeInterval(-16 * 3_600))
    let story = TopicStory(
        outlets: [
            TopicOutlet(id: 1, name: "Yahoo", title: "A new Firefox video reunites all your favorite early internet celebrities", url: "https://news.yahoo.com/a", publishedAt: lead.publishedAt),
            TopicOutlet(id: 2, name: "KHOU", title: "\u{2018}The internet used to be fun\u{2019}: Firefox reunites 2000s meme stars", url: "https://www.khou.com/b", publishedAt: now),
            TopicOutlet(id: 3, name: "The Cool Down on MSN", title: "Firefox ad takes aim at AI and tracking", url: "https://www.msn.com/c", publishedAt: now),
            TopicOutlet(id: 4, name: "Ad Age", title: "Watch the newest commercials from Ford, Kalshi, Firefox and more", url: "https://adage.com/d", publishedAt: now),
        ],
        discussion: TopicDiscussion(id: 9, points: 10, comments: 4, url: "https://news.ycombinator.com/item?id=1"))
    return VStack(spacing: 0) {
        StoryRowView(item: FeedItem(item: lead, source: topic, story: story))
        StoryRowView(item: FeedItem(item: lead, source: topic, story: story), isPhone: true)
    }
    .padding(8)
    .frame(width: 410)
    .background(Color.ofSurface)
}
