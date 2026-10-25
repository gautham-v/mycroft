import OpenfeedCore
import SwiftUI

/// SF Symbols standing in for the stroke icons in src/components/icons.tsx (24-unit, 1.75 stroke).
/// Prefer the outline (non-.fill) variants to keep the stroke look; no emoji anywhere.
enum OFIcon: String, CaseIterable {
    /// RefreshIcon
    case refresh = "arrow.clockwise"
    /// BookmarkIcon (outline) / filled when saved
    case bookmark = "bookmark"
    case bookmarkFilled = "bookmark.fill"
    /// ExternalIcon (open original)
    case external = "arrow.up.right.square"
    /// ExpandIcon / CollapseIcon (full-screen reader)
    case expand = "arrow.up.left.and.arrow.down.right"
    case collapse = "arrow.down.right.and.arrow.up.left"
    /// ShareIcon
    case share = "square.and.arrow.up"
    /// SendIcon (Send to)
    case send = "paperplane"
    /// CheckIcon
    case check = "checkmark"
    /// BackIcon
    case back = "chevron.left"
    /// PlusIcon
    case plus = "plus"
    /// CloseIcon
    case close = "xmark"
    /// ListIcon
    case list = "list.bullet"
    /// InboxIcon (All view, Feed tab)
    case inbox = "tray"
    /// PlayIcon (video thumbnail glyph)
    case play = "play.fill"
    /// VideoIcon (Video view)
    case video = "play.rectangle"
    /// HeadphonesIcon (Podcasts view, podcast thumbnails)
    case headphones = "headphones"
    /// CommentIcon (HN comments)
    case comment = "bubble.left"
    /// SidebarIcon (show/hide sidebar)
    case sidebar = "sidebar.left"
    /// ChevronIcon (folder disclosure)
    case chevron = "chevron.right"
    /// GearIcon (Settings)
    case gear = "gearshape"
    /// ArticleIcon (Articles view)
    case article = "doc.text"
    /// PostIcon (Posts view)
    case post = "text.bubble"
    /// GripIcon (drag handle)
    case grip = "line.3.horizontal"
    /// MoreIcon (row options)
    case more = "ellipsis"
    /// FolderIcon (Sources tab, folders)
    case folder = "folder"
    /// SearchIcon
    case search = "magnifyingglass"
    /// KeyboardIcon (shortcuts)
    case keyboard = "keyboard"
    /// Saved tab / view (same as bookmark)
    case saved = "bookmark.circle"

    var image: Image { Image(systemName: rawValue) }
}

/// Icon for each sidebar view row (sidebar.tsx).
extension FeedView {
    var icon: OFIcon {
        switch self {
        case .all: .inbox
        case .saved: .bookmark
        case .articles: .article
        case .posts: .post
        case .video: .video
        case .podcasts: .headphones
        }
    }
}

/// The hand-drawn feed mark (ArcIcon) as a stroked shape in a 24×24 box. The dot is `FeedMarkDot` (filled).
/// Usage: `FeedMark().stroke(.ofLogo, style: StrokeStyle(lineWidth: 1.75 * size / 24, lineCap: .round))` plus `FeedMarkDot().fill(...)`.
struct FeedMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(4.4, 11.6))
        path.addCurve(to: p(12.6, 14.2), control1: p(7.6, 9.9), control2: p(11.3, 11.6))
        path.addCurve(to: p(12.7, 19.7), control1: p(13.5, 16), control2: p(13.7, 17.6))
        path.move(to: p(5.4, 4.3))
        path.addCurve(to: p(17.9, 10.6), control1: p(10.4, 5.2), control2: p(15.1, 6.1))
        path.addCurve(to: p(18.6, 19.5), control1: p(19.7, 13.4), control2: p(20.1, 16.4))
        return path
    }
}

struct FeedMarkDot: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        return Path(ellipseIn: CGRect(x: rect.minX + 4.4 * s, y: rect.minY + 16.6 * s, width: 3.3 * s, height: 3.3 * s))
    }
}

/// The logo glyph at a given size and color.
struct FeedMarkIcon: View {
    var size: CGFloat = 18
    var color: Color = .ofLogo

    var body: some View {
        ZStack {
            FeedMark().stroke(color, style: StrokeStyle(lineWidth: 1.75 * size / 24 * 1.4, lineCap: .round))
            FeedMarkDot().fill(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
