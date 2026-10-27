import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Design tokens ported from src/app/globals.css (:root and the dark block). Neutral Apple greys,
// blue accent; teal only for the logo. On desktop the sidebar sits on `ofGround` (translucent on
// macOS) and the list and reader are flush `ofSurface` columns; on phones they go full-bleed.
//
// Names carry an `of` prefix so they never collide with SwiftUI's own ShapeStyle members
// (.selection, .primary, ...). Use them as `Color.ofInk` or `.foregroundStyle(.ofInk)`.

extension Color {
    /// A color that resolves per light/dark appearance (follows `.preferredColorScheme`).
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark, alpha: darkAlpha) : UIColor(rgb: light, alpha: lightAlpha)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(rgb: dark, alpha: darkAlpha) : NSColor(rgb: light, alpha: lightAlpha)
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
    static let ofGround = Color(light: 0xF2F2F4, dark: 0x2A2A2C)
    /// List and reader panels, sheets, cards.
    static let ofSurface = Color(light: 0xFFFFFF, dark: 0x212121)
    /// Selected list row.
    static let ofSelection = Color(light: 0xE8E8EC, dark: 0x383839)
    /// Hovered list row / button.
    static let ofHover = Color(light: 0xF4F4F6, dark: 0x2C2C2D)
    /// Sidebar rows sit on ground, so they need their own hover/selection. Tints, not solids, so the
    /// translucent macOS sidebar shows through them; on opaque ground they match E9E9ED/353537 and
    /// E1E1E6/3F3F42.
    static let ofNavHover = Color(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.05)
    static let ofNavSelection = Color(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.10)
    /// Dividers on the sidebar (its edge, above the footer, the search box): ofHairline as a tint.
    static let ofNavHairline = Color(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06)
    /// Titles, primary text.
    static let ofInk = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    /// Body text.
    static let ofBody = Color(light: 0x3A3A3C, dark: 0xD1D1D6)
    /// Secondary text, meta lines, section labels (Claude desktop's grey, brighter than Apple's).
    static let ofMuted = Color(light: 0x5E5E63, dark: 0xB4B4B4)
    /// Tertiary text, placeholder icons.
    static let ofFaint = Color(light: 0xAEAEB2, dark: 0x636366)
    /// Control borders.
    static let ofBorder = Color(light: 0xD2D2D7, dark: 0x454545)
    /// Dividers between rows and sections.
    static let ofHairline = Color(light: 0xE5E5EA, dark: 0x373737)
    /// Scroller knob (macOS), Claude desktop's grey.
    static let ofScroller = Color(light: 0xBDBDC2, dark: 0x767676)
    /// Search box on the sidebar (Claude Code's: lighter than the sidebar behind it). Translucent on
    /// macOS, where the sidebar is.
    #if os(macOS)
    static let ofField = Color(light: 0xFFFFFF, lightAlpha: 0.6, dark: 0xFFFFFF, darkAlpha: 0.05)
    #else
    static let ofField = Color(light: 0xFFFFFF, dark: 0x343436)
    #endif
    /// Code background, chips, skeletons, thumbnail placeholders.
    static let ofCode = Color(light: 0xF0F0F3, dark: 0x2E2E30)
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
    static var ofNavHairline: Color { Color.ofNavHairline }
    static var ofInk: Color { Color.ofInk }
    static var ofBody: Color { Color.ofBody }
    static var ofMuted: Color { Color.ofMuted }
    static var ofFaint: Color { Color.ofFaint }
    static var ofBorder: Color { Color.ofBorder }
    static var ofHairline: Color { Color.ofHairline }
    static var ofScroller: Color { Color.ofScroller }
    static var ofField: Color { Color.ofField }
    static var ofCode: Color { Color.ofCode }
    static var ofAccent: Color { Color.ofAccent }
    static var ofLogo: Color { Color.ofLogo }
    static var ofDanger: Color { Color.ofDanger }
    static var ofOK: Color { Color.ofOK }
}

extension View {
    /// A bar that content scrolls under (the list header, the reader toolbar): ofSurface at 70% over
    /// a blur of the rows or article passing beneath.
    func frostedBar() -> some View {
        background(Color.ofSurface.opacity(0.7))
            .background(.ultraThinMaterial)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#endif

/// Layout metrics from the web app's Tailwind classes (px → pt 1:1).
enum Metrics {
    /// Desktop sidebar width (`w-[230px]`).
    static let sidebarWidth: CGFloat = 230
    /// Desktop sidebar drag limits.
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 340
    /// Item list column: 410 on desktop (lg), 380 on tablet (md).
    static let listWidth: CGFloat = 410
    /// Desktop list column drag limits.
    static let listMinWidth: CGFloat = 320
    static let listMaxWidth: CGFloat = 520
    static let listWidthTablet: CGFloat = 380
    /// Reading column side padding, 20pt (phone) / 32pt (md+). The column's width is a setting
    /// (`AppSettings.readerColumnWidth`, 640 by default).
    static let readerPaddingPhone: CGFloat = 20
    static let readerPaddingWide: CGFloat = 32
    /// Video player max width in theater layout.
    static let theaterMaxWidth: CGFloat = 960
    /// Desktop list/reader header height.
    static let desktopHeaderHeight: CGFloat = 54
    /// Desktop icon buttons 30pt; phone touch targets 44pt.
    static let desktopIconButton: CGFloat = 30
    /// Reader toolbar actions on desktop: 28pt boxes 4pt apart, glyphs at 15pt, one grey (like Claude's bar).
    static let readerActionButton: CGFloat = 28
    static let readerActionSpacing: CGFloat = 4
    static let readerActionGlyph: CGFloat = 15
    static let touchTarget: CGFloat = 44
    /// Phone tab bar item min height.
    static let tabBarItemHeight: CGFloat = 52
    /// Sidebar row height and corner radius.
    static let sidebarRowHeight: CGFloat = 34
    static let rowRadius: CGFloat = 6
    /// macOS: the title bar is hidden, so the traffic lights sit over the content on the top row.
    /// Like the Claude desktop app the row is 44pt and the lights are centred 22pt from the top and
    /// left edges (TrafficLights), ending at ~69pt; the sidebar toggle follows at `sidebarToggleX`.
    static let topBarHeight: CGFloat = 44
    static let trafficLightCenter: CGFloat = 22
    static let sidebarToggleX: CGFloat = 80
    /// Leading space that clears the lights (full-screen reader).
    static let trafficLightInset: CGFloat = 84
    /// Air between the list header row and the first row: with the list's own 1pt, the 16pt that
    /// rows keep from the column's sides (8pt row inset + 8pt from the list), so a selected first row
    /// sits evenly in its corner.
    static let listHeaderGap: CGFloat = 15
    /// Item row padding (px-2.5 py-[11px]); the hairline between rows is inset by rowPaddingH on both
    /// sides, lining up with the badge and title.
    static let rowPaddingH: CGFloat = 10
    static let rowPaddingV: CGFloat = 11
    /// Source badge in list rows; reader header badge.
    static let rowBadge: CGFloat = 16
    /// List thumbnail (h-[42px] w-[64px], 3pt corners).
    static let thumbWidth: CGFloat = 64
    static let thumbHeight: CGFloat = 42
    static let thumbRadius: CGFloat = 3
}
