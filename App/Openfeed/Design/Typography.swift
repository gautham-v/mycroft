import SwiftUI

// The web app's current globals.css uses system font stacks (not Inter / IBM Plex Mono as in the
// original SPEC): -apple-system / SF Pro for UI, ui-monospace / SF Mono for mono, ui-serif / New York
// for the reader. So no font files are bundled; SwiftUI's system designs match exactly.

enum OFFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    // Item list (item-row.tsx)
    /// Title: 14.5 / 500, leading 1.3, tracking -0.005em.
    static let itemTitle = ui(14.5, .medium)
    /// Meta line: 12.5, source name in ink/500, rest muted.
    static let itemMeta = ui(12.5)
    static let itemMetaSource = ui(12.5, .medium)
    /// Snippet (phone only): 13 muted, 2-line clamp.
    static let itemSnippet = ui(13)
    /// Duration badge on thumbnails: 10 / 500, tabular.
    static let thumbBadge = ui(10, .medium).monospacedDigit()

    // Headers (openfeed-app.tsx)
    /// Desktop list header title 15 / 600, tracking -0.01em; subline 13 muted.
    static let listHeaderTitle = ui(15, .semibold)
    static let listHeaderSubline = ui(13)
    /// Phone large title 28 / 700, tracking -0.02em; subline 12 muted.
    static let phoneTitle = ui(28, .bold)
    static let phoneSubline = ui(12)
    /// Phone filter chips 13 / 500.
    static let chip = ui(13, .medium)
    /// Bottom tab labels 11 / 500.
    static let tabLabel = ui(11, .medium)

    // Sidebar (sidebar.tsx)
    static let sidebarRow = ui(14)
    static let sidebarFooter = ui(13.5)
    static let sidebarSection = ui(12, .semibold)

    // Reader (reader.tsx)
    /// Toolbar meta (host · date · read time) 13 muted.
    static let readerToolbarMeta = ui(13)
    /// Byline row under the headline: 14 muted, source name ink/500.
    static let readerByline = ui(14)
    /// Video title 20 (phone) / 22 (md+) / 600.
    static let videoTitle = ui(20, .semibold)
    static let videoTitleWide = ui(22, .semibold)

    /// Reader headline size per text-size setting (HEADLINE_SIZE in reader.tsx), weight 600, leading 1.12.
    static func headlineSize(_ size: TextSizeSetting, wide: Bool) -> CGFloat {
        switch size {
        case .s: wide ? 32 : 26
        case .m: wide ? 36 : 30
        case .l: wide ? 40 : 34
        }
    }

    /// Reader body size per text-size setting (prose-openfeed): 16 / 17.5 / 19.5, line height 1.6.
    static func bodySize(_ size: TextSizeSetting) -> CGFloat {
        switch size {
        case .s: 16
        case .m: 17.5
        case .l: 19.5
        }
    }
}
