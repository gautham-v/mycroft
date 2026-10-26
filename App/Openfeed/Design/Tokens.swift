import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Design tokens ported from src/app/globals.css (:root and the dark block). Neutral Apple greys,
// blue accent; teal only for the logo. On desktop the sidebar sits on `ofGround` and the list and
// reader are inset `ofSurface` panels; on phones the panels go full-bleed.
//
// Names carry an `of` prefix so they never collide with SwiftUI's own ShapeStyle members
// (.selection, .primary, ...). Use them as `Color.ofInk` or `.foregroundStyle(.ofInk)`.

extension Color {
    /// A color that resolves per light/dark appearance (follows `.preferredColorScheme`).
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #endif
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// "#RRGGBB" → Color (used for TextFormat.badgePalette). Falls back to gray.
    init(hexString: String) {
        let s = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        self.init(hex: UInt32(s, radix: 16) ?? 0x888888)
    }

    /// Window background; sidebar background on desktop.
    static let ofGround = Color(light: 0xF2F2F4, dark: 0x000000)
    /// List and reader panels, sheets, cards.
    static let ofSurface = Color(light: 0xFFFFFF, dark: 0x161618)
    /// Selected list row.
    static let ofSelection = Color(light: 0xE8E8EC, dark: 0x3A3A3D)
    /// Hovered list row / button.
    static let ofHover = Color(light: 0xF4F4F6, dark: 0x1C1C1F)
    /// Sidebar rows sit on ground, so they need darker hover/selection than panel rows.
    static let ofNavHover = Color(light: 0xE9E9ED, dark: 0x1C1C1F)
    static let ofNavSelection = Color(light: 0xE1E1E6, dark: 0x3A3A3D)
    /// Titles, primary text.
    static let ofInk = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    /// Body text.
    static let ofBody = Color(light: 0x3A3A3C, dark: 0xD1D1D6)
    /// Secondary text, meta lines, icons.
    static let ofMuted = Color(light: 0x6E6E73, dark: 0x98989D)
    /// Tertiary text, placeholder icons.
    static let ofFaint = Color(light: 0xAEAEB2, dark: 0x636366)
    /// Control borders.
    static let ofBorder = Color(light: 0xD2D2D7, dark: 0x2C2C2E)
    /// Dividers between rows and sections.
    static let ofHairline = Color(light: 0xE5E5EA, dark: 0x232326)
    /// Code background, chips, skeletons, thumbnail placeholders.
    static let ofCode = Color(light: 0xF0F0F3, dark: 0x242427)
    /// The one accent: links, active tab, saved state, focus ring.
    static let ofAccent = Color(light: 0x007AFF, dark: 0x0A84FF)
    /// Logo teal (app icon, feed mark).
    static let ofLogo = Color(light: 0x0F6E6E, dark: 0x2F9C9C)
    static let ofDanger = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let ofOK = Color(light: 0x34C759, dark: 0x30D158)
}

extension ShapeStyle where Self == Color {
    static var ofGround: Color { Color.ofGround }
    static var ofSurface: Color { Color.ofSurface }
    static var ofSelection: Color { Color.ofSelection }
    static var ofHover: Color { Color.ofHover }
    static var ofNavHover: Color { Color.ofNavHover }
    static var ofNavSelection: Color { Color.ofNavSelection }
    static var ofInk: Color { Color.ofInk }
    static var ofBody: Color { Color.ofBody }
    static var ofMuted: Color { Color.ofMuted }
    static var ofFaint: Color { Color.ofFaint }
    static var ofBorder: Color { Color.ofBorder }
    static var ofHairline: Color { Color.ofHairline }
    static var ofCode: Color { Color.ofCode }
    static var ofAccent: Color { Color.ofAccent }
    static var ofLogo: Color { Color.ofLogo }
    static var ofDanger: Color { Color.ofDanger }
    static var ofOK: Color { Color.ofOK }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Layout metrics from the web app's Tailwind classes (px → pt 1:1).
enum Metrics {
    /// Desktop sidebar width (`w-[230px]`).
    static let sidebarWidth: CGFloat = 230
    /// Item list column: 410 on desktop (lg), 380 on tablet (md).
    static let listWidth: CGFloat = 410
    static let listWidthTablet: CGFloat = 380
    /// Reading column max width (`max-w-[640px]`), with 20pt (phone) / 32pt (md+) side padding.
    static let readerMaxWidth: CGFloat = 640
    static let readerPaddingPhone: CGFloat = 20
    static let readerPaddingWide: CGFloat = 32
    /// Video player max width in theater layout.
    static let theaterMaxWidth: CGFloat = 960
    /// Desktop panels are inset 10pt from the window with 6pt corners.
    static let panelInset: CGFloat = 10
    static let panelRadius: CGFloat = 6
    /// Desktop list/reader header height.
    static let desktopHeaderHeight: CGFloat = 54
    /// Desktop icon buttons 30pt; phone touch targets 44pt.
    static let desktopIconButton: CGFloat = 30
    static let touchTarget: CGFloat = 44
    /// Phone tab bar item min height.
    static let tabBarItemHeight: CGFloat = 52
    /// Sidebar row height and corner radius.
    static let sidebarRowHeight: CGFloat = 32
    static let rowRadius: CGFloat = 4
    /// Item row padding (px-2.5 py-[11px]) and the inset hairline start (10 + 24 + 12).
    static let rowPaddingH: CGFloat = 10
    static let rowPaddingV: CGFloat = 11
    static let rowDividerInset: CGFloat = 46
    /// Source badge in list rows; reader header badge.
    static let rowBadge: CGFloat = 16
    /// List thumbnail (h-[42px] w-[64px], 3pt corners).
    static let thumbWidth: CGFloat = 64
    static let thumbHeight: CGFloat = 42
    static let thumbRadius: CGFloat = 3
}
