import OpenDispatchCore
import SwiftUI

/// Explore's Posts section, shared by the New Tab page (Mac, iPad) and the iPhone's Explore page: a row of places
/// (Reddit, X, Bluesky, Hacker News, each with its count or a spinner) over the shown place's posts. Each place lands on its
/// own; X shows a sign-in note until the app is signed in to it. A post opens in the reader with its comments under it.
struct ExplorePostsSection: View {
    var isPhone = false
    /// How many posts to show; nil for all.
    var limit: Int?
    let open: (ExploreTarget, Bool) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let explore = model.explore
        let place = explore.shownPostPlace
        VStack(alignment: .leading, spacing: isPhone ? 4 : 8) {
            ExplorePlacePicker(isPhone: isPhone)
            Group {
                switch explore.posts[place] {
                case nil:
                    if place == .x {
                        if model.accounts.checked {
                            ExploreSignInNote(account: .x, isPhone: isPhone)
                        } else {
                            ExploreSkeleton(style: .rows, isPhone: isPhone)
                        }
                    }
                case .idle?, .loading?:
                    ExploreSkeleton(style: .rows, isPhone: isPhone)
                case .failed(let message)?:
                    if place == .x, !model.accounts.isSignedIn(.x) {
                        ExploreSignInNote(account: .x, isPhone: isPhone)
                    } else {
                        ExploreFailure(what: place.name, message: message) { explore.retryPosts(place) }
                    }
                case .loaded(let posts)?:
                    if posts.isEmpty {
                        ExploreEmptyNote(text: "No posts on \(place.name) for \u{201C}\(explore.query)\u{201D}")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(limit.map { Array(posts.prefix($0)) } ?? posts) { post in
                                let target = ExploreTarget.post(post)
                                ExplorePostRow(post: post, isPhone: isPhone, isOpening: explore.opening == target.id) { open(target, $0) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, isPhone ? 16 : 0)
        }
    }
}

/// The places to show posts from, as chips: the name, then the count once it has answered.
struct ExplorePlacePicker: View {
    var isPhone = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let explore = model.explore
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(DiscussionPlace.searched, id: \.self) { place in
                    let selected = explore.shownPostPlace == place
                    Button { explore.pickPostPlace(place) } label: {
                        HStack(spacing: 5) {
                            Text(place.name)
                            switch explore.posts[place] {
                            case .loading?:
                                ProgressView().controlSize(.mini)
                            case .loaded(let posts)?:
                                Text("\(posts.count)").monospacedDigit().opacity(0.6)
                            default:
                                EmptyView()
                            }
                        }
                        .font(OFFont.ui(isPhone ? 14 : 12.5, .medium))
                        .foregroundStyle(selected ? Color.ofSurface : Color.ofBody)
                        .padding(.horizontal, isPhone ? 13 : 10)
                        .frame(height: isPhone ? 32 : 26)
                        .background(selected ? Color.ofInk : Color.ofCode, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, isPhone ? 16 : 0)
        }
        .scrollIndicators(.hidden)
    }
}

/// A post: the community's icon or the author's avatar, "r/Community · 20h" or "Name @handle · 2h", the headline or
/// the post's text, its votes or likes and comments, and its picture.
struct ExplorePostRow: View {
    let post: DiscussionPost
    var isPhone = false
    let isOpening: Bool
    /// Opens it; true for a new tab.
    let open: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var avatarSize: CGFloat { isPhone ? 32 : 28 }

    var body: some View {
        Button { open(false) } label: {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    meta
                    Text(post.title ?? post.text ?? post.headline)
                        .font(OFFont.ui(isPhone ? 15 : 13.5, post.title != nil ? .medium : .regular))
                        .foregroundStyle(hovering ? Color.ofAccent : Color.ofInk)
                        .lineLimit(post.title != nil ? 3 : 5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let stats = ExploreFormat.postStats(post) {
                        stats
                            .font(OFFont.ui(isPhone ? 13 : 12))
                            .foregroundStyle(.ofMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOpening {
                    ProgressView().controlSize(.small).frame(width: 24)
                } else if let thumb = post.thumbnailUrl, let url = URL(string: thumb) {
                    CachedAsyncImage(url: url, maxPixelSize: 160) { image in
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
            if let url = URL(string: post.url) {
                Button("Open in Browser") { openURL(url) }
                Button("Copy Link") { ReaderPasteboard.copy(url) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([ExploreFormat.postMeta(post), post.title ?? post.text ?? "", ExploreFormat.postStatsSpoken(post)].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @ViewBuilder private var avatar: some View {
        if let avatar = post.avatarUrl, let url = URL(string: avatar) {
            CachedAsyncImage(url: url, maxPixelSize: avatarSize * 3) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                Color.ofCode
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            SourceBadge(host: ExploreFormat.host(post.place), title: post.place.name, size: avatarSize)
        }
    }

    private var meta: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let lead = Text(verbatim: ExploreFormat.postSource(post)).fontWeight(.medium).foregroundStyle(Color.ofInk)
            var tail = ""
            if post.place != .reddit, let handle = post.handle, post.author != nil, post.place != .hackerNews { tail += " @\(handle)" }
            if let date = post.published { tail += " \u{00B7} " + RelativeTime.format(date, now: context.date) }
            return Text("\(lead)\(Text(verbatim: tail).foregroundStyle(Color.ofMuted))")
                .font(OFFont.ui(isPhone ? 13 : 12))
                .lineLimit(1)
        }
    }
}

/// X needs the app signed in before it shows posts or replies.
struct ExploreSignInNote: View {
    let account: WebAccount
    var isPhone = false
    var what = "posts"
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to \(account.name) to see \(what) here")
                    .font(OFFont.ui(isPhone ? 15 : 13.5, .medium))
                    .foregroundStyle(.ofInk)
                Text("OpenDispatch has its own sign-in; it can\u{2019}t use your browser\u{2019}s. You can sign out in Settings \u{203A} Integrations.")
                    .font(OFFont.ui(isPhone ? 13 : 12))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.accounts.signingIn = .account(account) } label: {
                Text("Sign In")
                    .font(OFFont.ui(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.ofAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(isPhone ? 0 : 10)
        .background {
            if !isPhone { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ofCode) }
        }
    }
}

extension ExploreFormat {
    /// The site a place's posts are on, for its favicon.
    static func host(_ place: DiscussionPlace) -> String {
        switch place {
        case .reddit: "reddit.com"
        case .x: "x.com"
        case .bluesky: "bsky.app"
        case .hackerNews: "news.ycombinator.com"
        case .youtube: "youtube.com"
        }
    }

    /// Who or where: "r/LoveIsBlindNetflix", "Murray Hill Guy", "dhouston on Hacker News".
    static func postSource(_ post: DiscussionPost) -> String {
        switch post.place {
        case .reddit: post.community ?? post.author ?? "Reddit"
        case .hackerNews: post.author.map { "\($0) on Hacker News" } ?? "Hacker News"
        default: post.author ?? post.handle.map { "@" + $0 } ?? post.place.name
        }
    }

    static func postMeta(_ post: DiscussionPost) -> String {
        var parts = [postSource(post)]
        if let date = post.published { parts.append(RelativeTime.format(date)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "1.6K", "980".
    static func count(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }

    /// "▲ 3.5K · 💬 1.6K" with SF Symbols: an arrow for votes and points, a heart for likes.
    static func postStats(_ post: DiscussionPost) -> Text? {
        let likes = post.place == .x || post.place == .bluesky
        let score = post.score.map { n in
            Text("\(Text(Image(systemName: likes ? "heart" : "arrowtriangle.up.fill")).font(.system(size: likes ? 10 : 8)))\(Text(verbatim: " " + count(n)))")
        }
        let comments = post.comments.map { n in
            Text("\(Text(Image(systemName: "bubble.left")).font(.system(size: 10)))\(Text(verbatim: " " + count(n)))")
        }
        switch (score, comments) {
        case let (s?, c?): return Text("\(s)\(Text(verbatim: "   "))\(c)")
        case let (s?, nil): return s
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    static func postStatsSpoken(_ post: DiscussionPost) -> String {
        let likes = post.place == .x || post.place == .bluesky
        var parts: [String] = []
        if let s = post.score { parts.append(likes ? "\(s) likes" : "\(s) votes") }
        if let c = post.comments { parts.append(c == 1 ? "1 comment" : "\(c) comments") }
        return parts.joined(separator: ", ")
    }
}
