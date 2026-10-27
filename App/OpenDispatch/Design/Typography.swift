import SwiftUI

// System fonts only, no bundled font files: SF (the default design) for all UI and metadata; article
// text in SF, New York (`.serif`), Charter or Iowan Old Style (all installed on macOS and iOS). No
// monospace anywhere outside code blocks in articles (reader.css).

enum OFFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Article text in the reader font setting (the headline and the summary shown when extraction fails).
    static func reader(_ font: ReaderFontSetting, _ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch font {
        case .sans: ui(size, weight)
        case .serif: serif(size, weight)
        case .charter: .custom("Charter", size: size).weight(weight)
        case .iowan: .custom("Iowan Old Style", size: size).weight(weight)
        }
    }

    // Item list (item-row.tsx)
    /// Title: 14.5 regular, the sidebar's row style; leading 1.3, tracking -0.005em.
    static let itemTitle = ui(14.5)
    /// Meta line (source · time): 13 regular muted, the sidebar's section-label style.
    static let itemMeta = ui(13)
    /// X-post snippet: 13 muted, one line (macOS / iPad rows).
    static let itemSnippet = ui(13)
    /// Duration badge on thumbnails: 10 / 500, tabular.
    static let thumbBadge = ui(10, .medium).monospacedDigit()

    // Headers (openfeed-app.tsx)
    /// Desktop list header: title ink, "updated 5m ago" muted, both regular at the sidebar's row size
    /// like the reader toolbar's source · time beside it.
    static let listHeaderTitle = ui(14.5)
    static let listHeaderSubline = ui(14.5)
    /// Bottom tab labels 11 / 500.
    static let tabLabel = ui(11, .medium)

    // Sidebar (sidebar.tsx)
    static let sidebarRow = ui(14.5)
    static let sidebarFooter = ui(13.5)
    static let sidebarSection = ui(12, .semibold)

    // Reader (reader.tsx)
    /// Toolbar title (source · time), at the sidebar's row size like Claude's thread title.
    static let readerToolbarTitle = ui(14.5)
    /// Byline row under the headline: 14 muted, source name ink/500.
    static let readerByline = ui(14)
    /// Video title 20 (phone) / 22 (md+) / 600.
    static let videoTitle = ui(20, .semibold)
    static let videoTitleWide = ui(22, .semibold)

    /// Reader headline size per text-size setting (HEADLINE_SIZE in reader.tsx), weight 600, leading 1.12.
    static func headlineSize(_ size: TextSizeSetting, wide: Bool) -> CGFloat {
        switch size {
        case .xxs: wide ? 28 : 23
        case .xs: wide ? 30 : 24
        case .s: wide ? 32 : 26
        case .m: wide ? 36 : 30
        case .l: wide ? 40 : 34
        case .xl: wide ? 42 : 36
        case .xxl: wide ? 44 : 38
        case .xxxl: wide ? 46 : 40
        }
    }

    /// Reader body size per text-size setting (prose-opendispatch data-size in reader.css).
    static func bodySize(_ size: TextSizeSetting) -> CGFloat {
        switch size {
        case .xxs: 14
        case .xs: 15
        case .s: 16
        case .m: 17.5
        case .l: 19.5
        case .xl: 21
        case .xxl: 23
        case .xxxl: 25
        }
    }
}
