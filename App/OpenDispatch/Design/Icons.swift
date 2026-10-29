import OpenDispatchCore
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
    /// HeadphonesIcon (Podcasts view, podcast thumbnails, the reader's Listen button)
    case headphones = "headphones"
    /// CommentIcon (HN comments)
    case comment = "bubble.left"
    /// SidebarIcon (show/hide sidebar)
    case sidebar = "sidebar.left"
    /// Split view (two reader panes)
    case split = "rectangle.split.2x1"
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
    /// The reader's More menu
    case moreMenu = "ellipsis.circle"
    /// FolderIcon (Sources tab, folders)
    case folder = "folder"
    /// SearchIcon
    case search = "magnifyingglass"
    /// KeyboardIcon (shortcuts)
    case keyboard = "keyboard"
    /// Saved tab / view (same as bookmark)
    case saved = "bookmark.circle"
    /// The quoted post under a quote post on X (list rows)
    case quoted = "arrow.turn.down.right"
    /// Highlights & Notes (reader bar, sidebar row)
    case highlighter = "highlighter"
    /// History
    case history = "clock"
    /// A highlight's note (its popover)
    case note = "note.text"
    /// Remove a highlight (its popover)
    case trash = "trash"
    /// The New Tab page's address field
    case globe = "globe"
    /// Notify on New Posts (a source's menu, the Notifications settings pane)
    case bell = "bell"
    case bellOff = "bell.slash"
    /// A topic (its sidebar row)
    case topic = "number"
    /// A paywalled site's article (list rows' mark)
    case lock = "lock"

    /// macOS draws its toolbar and sidebar icons from our own symbols (Resources/Assets.xcassets/Icons):
    /// thin, rounded 24-unit strokes like the Claude desktop app's, where SF Symbols read heavier. The
    /// raw value stays the SF Symbol, which iOS and system labels (`systemImage:`) keep using.
    var image: Image {
        #if os(macOS)
        if let name = customSymbol { return Image(name) }
        #endif
        return Image(systemName: rawValue)
    }

    private var customSymbol: String? {
        switch self {
        case .sidebar: "of.sidebar"
        case .split: "of.split"
        case .search: "of.search"
        case .refresh: "of.refresh"
        case .bookmark: "of.bookmark"
        case .bookmarkFilled: "of.bookmark.fill"
        case .external: "of.external"
        case .share: "of.share"
        case .send: "of.send"
        case .expand: "of.expand"
        case .collapse: "of.collapse"
        case .close: "of.close"
        case .plus: "of.plus"
        case .headphones: "of.headphones"
        case .highlighter: "of.highlighter"
        case .moreMenu: "of.more"
        default: nil
        }
    }
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
