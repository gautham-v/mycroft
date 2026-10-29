import OpenDispatchCore
import SwiftUI

/// The pieces of Explore's results that the New Tab page (Mac, iPad) and the iPhone's Explore page share.

/// The metadata lines under results, worded as YouTube and iTunes give them.
enum ExploreFormat {
    /// "Channel · 1.4M views".
    static func videoMeta(_ video: ExploreVideo) -> String {
        [video.channel, video.views].compactMap { $0 }.joined(separator: " · ")
    }

    /// "1.4M views · 2 weeks ago", for a row with the channel above it.
    static func videoStats(_ video: ExploreVideo) -> String {
        [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Show · Oct 28 · 41 min".
    static func episodeMeta(_ episode: ExploreEpisode) -> String {
        var parts = [episode.show]
        if let date = episode.published { parts.append(date.formatted(.dateTime.month(.abbreviated).day())) }
        if let seconds = episode.durationSeconds, seconds > 0 { parts.append(duration(seconds: seconds)) }
        return parts.joined(separator: " · ")
    }

    /// "41 min", "1 h 5 min".
    static func duration(seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// What a source is, then its subtitle: "YouTube channel · 683K subscribers", "Podcast · Publisher", "Feed · host".
    /// A channel's subtitle already starts with "YouTube" ("YouTube · 683K subscribers"), so only its count is kept.
    static func sourceMeta(_ result: SourceSearchResult) -> String {
        var subtitle = result.subtitle
        let kind = switch result.kind {
        case .youtube: "YouTube channel"
        case .podcast: "Podcast"
        default: "Feed"
        }
        if result.kind == .youtube, subtitle.hasPrefix("YouTube") {
            subtitle = subtitle.dropFirst("YouTube".count).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
        }
        return subtitle.isEmpty ? kind : kind + " · " + subtitle
    }
}

/// A video's 16:9 thumbnail with its length in the corner; a spinner over it while the video opens.
struct ExploreThumb: View {
    let url: String
    var duration: String?
    var radius: CGFloat = 8
    var isOpening = false
    /// The width it is drawn at, in points, so the image is decoded no larger.
    var width: CGFloat = 220
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.ofCode
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: URL(string: url), maxPixelSize: width * max(displayScale, 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.ofCode
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration, !duration.isEmpty, !isOpening {
                    Text(duration)
                        .font(OFFont.thumbBadge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(4)
                }
            }
            .overlay {
                if isOpening {
                    Color.black.opacity(0.4)
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A podcast episode's artwork.
struct ExploreArtwork: View {
    let url: String?
    var size: CGFloat = 44
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        CachedAsyncImage(url: url.flatMap(URL.init(string:)), maxPixelSize: size * max(displayScale, 2)) { image in
            image.resizable().scaledToFill()
        } placeholder: { _ in
            Color.ofCode.overlay { OFIcon.headphones.image.font(.system(size: size * 0.4)).foregroundStyle(.ofFaint) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The circle a play control sits in: a spinner while the episode opens.
struct ExplorePlayBadge: View {
    var size: CGFloat = 28
    var isOpening = false

    var body: some View {
        ZStack {
            if isOpening {
                ProgressView().controlSize(.small)
            } else {
                OFIcon.play.image
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.ofInk)
                    .offset(x: size * 0.03)
            }
        }
        .frame(width: size, height: size)
        .background(Color.ofCode, in: Circle())
        .accessibilityHidden(true)
    }
}

/// A source to follow: its picture (a channel's avatar round, a podcast's artwork rounded, a site's favicon),
/// name, what it is, and Follow. A failed add shows its reason underneath.
struct ExploreSourceItem: View {
    let result: SourceSearchResult
    var avatarSize: CGFloat = 36
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(OFFont.ui(14, .semibold))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Text(ExploreFormat.sourceMeta(result))
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ExploreFollowButton(result: result)
            }
            if case .failed(let message) = model.sourceAdds[result.feedUrl] {
                Text(message)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, avatarSize + 10)
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        if let image = result.imageUrl, let url = URL(string: image) {
            CachedAsyncImage(url: url, maxPixelSize: avatarSize * 3) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                Color.ofCode
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(result.kind == .youtube ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            .accessibilityHidden(true)
        } else {
            SourceBadge(host: URLHost.host(of: result.siteUrl ?? result.feedUrl), title: result.title, size: avatarSize)
        }
    }
}

/// Follow / Following, through the Add Source flow (`AppModel.beginAddSource`): a spinner while it adds, Try Again
/// when it failed, Following once the source is in the library.
struct ExploreFollowButton: View {
    let result: SourceSearchResult
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.sourceAdds[result.feedUrl]
        let following = model.hasSource(feedUrl: result.feedUrl) || state == .added
        let adding = state == .adding
        var failed = false
        if case .failed = state { failed = true }
        return Button {
            model.beginAddSource(url: result.feedUrl)
        } label: {
            HStack(spacing: 4) {
                if adding {
                    ProgressView().controlSize(.mini)
                } else {
                    (following ? OFIcon.check : OFIcon.plus).image.font(.system(size: 10, weight: .bold))
                }
                Text(following ? "Following" : adding ? "Adding" : failed ? "Try Again" : "Follow")
                    .font(OFFont.ui(13, .semibold))
            }
            .foregroundStyle(following || adding ? Color.ofInk : Color.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(following || adding ? Color.ofCode : Color.ofAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(following || adding)
        .accessibilityLabel(following ? "Following \(result.title)" : adding ? "Following \(result.title), in progress" : "Follow \(result.title)")
    }
}

/// Follow / Following for the searched words as a topic: Follow stores a topic with the default options (it
/// doesn't open it); once it exists the button reads Following and opens it. A spinner while it is stored, and
/// Try Again if that failed.
struct ExploreTopicButton: View {
    let query: String
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var failed = false

    var body: some View {
        let topic = model.topic(matching: query)
        let following = topic != nil
        return Button {
            if let topic {
                model.navigate(sourceID: topic.id)
            } else {
                follow()
            }
        } label: {
            HStack(spacing: 4) {
                if adding {
                    ProgressView().controlSize(.mini)
                } else {
                    (following ? OFIcon.check : OFIcon.plus).image.font(.system(size: 10, weight: .bold))
                }
                Text(following ? "Following" : adding ? "Adding" : failed ? "Try Again" : "Follow")
                    .font(OFFont.ui(13, .semibold))
            }
            .foregroundStyle(following || adding ? Color.ofInk : Color.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(following || adding ? Color.ofCode : Color.ofAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(adding)
        .help(following ? "Open this topic" : "Follow this search as a topic, with new matches in the sidebar")
        .accessibilityLabel(following ? "Following \(query) as a topic" : "Follow \(query) as a topic")
        .accessibilityHint(following ? "Opens the topic" : "")
    }

    private func follow() {
        adding = true
        failed = false
        Task {
            do { try await model.followTopic(query: query) } catch { failed = true }
            adding = false
        }
    }
}

/// "Search the web for “…”": hands the query to the default browser (Google's results). Not a navigation, so
/// no spinner: it leaves the app.
struct ExploreWebRow: View {
    let query: String
    var isPhone = false
    @State private var hovered = false

    var body: some View {
        Button {
            if let url = ExploreStore.webSearchURL(query) { ReaderWebSupport.openExternally(url) }
        } label: {
            HStack(spacing: 10) {
                OFIcon.globe.image
                    .font(.system(size: isPhone ? 18 : 16))
                    .foregroundStyle(.ofMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Search the web for \u{201C}\(query)\u{201D}")
                        .font(OFFont.ui(isPhone ? 15 : 14, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Text("Opens in your browser")
                        .font(OFFont.ui(isPhone ? 13 : 12))
                        .foregroundStyle(.ofMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OFIcon.external.image
                    .font(.system(size: 14))
                    .foregroundStyle(.ofMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(hovered ? Color.ofSelection : Color.ofCode, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Search the web for \(query)")
        .accessibilityHint("Opens in your browser")
    }
}

/// A section that couldn't be searched, with a retry; the other sections are unaffected.
struct ExploreFailure: View {
    let what: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Couldn\u{2019}t search \(what)")
                .font(OFFont.ui(14, .medium))
                .foregroundStyle(.ofInk)
            Text(message)
                .font(OFFont.ui(12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry)
                .buttonStyle(.plain)
                .font(OFFont.ui(13, .medium))
                .foregroundStyle(.ofAccent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A section with nothing in it: a quiet line.
struct ExploreEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grey blocks standing in for rows while a section loads.
struct ExploreSkeleton: View {
    enum Style { case cards, rows }
    let style: Style
    var isPhone = false

    var body: some View {
        Group {
            switch style {
            case .cards:
                HStack(spacing: 12) {
                    ForEach(0..<(isPhone ? 2 : 3), id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Color.ofCode.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Color.ofCode.frame(height: 10).clipShape(Capsule())
                            Color.ofCode.frame(width: 70, height: 10).clipShape(Capsule())
                        }
                    }
                }
            case .rows:
                VStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 10) {
                            Color.ofCode.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Color.ofCode.frame(height: 10).clipShape(Capsule())
                                Color.ofCode.frame(width: 120, height: 10).clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
