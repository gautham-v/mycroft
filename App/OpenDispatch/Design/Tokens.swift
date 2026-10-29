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

    // Themed tokens (Themes.swift): the palette of the light and dark themes chosen in Settings → Themes,
    // the Default themes being the values these always had. Reading one inside a view's body makes the
    // view re-render when the theme or accent changes.

    /// Window background; sidebar background on desktop.
    static var ofGround: Color { ThemeRuntime.shared.colors.ground }
    /// The macOS sidebar's tint over its material: light on the Default themes, nearly opaque on the others
    /// so their color shows.
    static var ofSidebarGround: Color { ThemeRuntime.shared.colors.sidebarGround }
    /// List and reader panels, sheets, cards. iOS: a warm off-white (Duet's) that white cards sit on.
    static var ofSurface: Color { ThemeRuntime.shared.colors.surface }
    /// Selected list row.
    static var ofSelection: Color { ThemeRuntime.shared.colors.selection }
    /// Hovered list row / button.
    static var ofHover: Color { ThemeRuntime.shared.colors.hover }
    /// Sidebar rows sit on ground, so they need their own hover/selection. Tints, not solids, so the
    /// translucent macOS sidebar shows through them; on opaque ground they match E9E9ED/353537 and
    /// E1E1E6/3F3F42.
    static let ofNavHover = Color(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.05)
    static let ofNavSelection = Color(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.10)
    /// Dividers on the sidebar (its edge, above the footer, the search box): ofHairline as a tint.
    static let ofNavHairline = Color(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06)
    /// Titles, primary text.
    static var ofInk: Color { ThemeRuntime.shared.colors.ink }
    /// Body text.
    static var ofBody: Color { ThemeRuntime.shared.colors.body }
    /// Secondary text, meta lines, section labels (Claude desktop's grey, brighter than Apple's).
    static var ofMuted: Color { ThemeRuntime.shared.colors.muted }
    /// Tertiary text, placeholder icons.
    static var ofFaint: Color { ThemeRuntime.shared.colors.faint }
    /// Titles of items already read: quieter than ink, still readable.
    static var ofRead: Color { ThemeRuntime.shared.colors.read }
    /// Control borders.
    static var ofBorder: Color { ThemeRuntime.shared.colors.border }
    /// Dividers between rows and sections (warmer on iOS, to match its ground).
    static var ofHairline: Color { ThemeRuntime.shared.colors.hairline }
    /// Scroller knob (macOS), Claude desktop's grey.
    static var ofScroller: Color { ThemeRuntime.shared.colors.scroller }
    /// Search box on the sidebar (Claude Code's: lighter than the sidebar behind it). Translucent on
    /// macOS, where the sidebar is.
    #if os(macOS)
    static let ofField = Color(light: 0xFFFFFF, lightAlpha: 0.6, dark: 0xFFFFFF, darkAlpha: 0.05)
    #else
    static var ofField: Color { ThemeRuntime.shared.colors.field }
    #endif
    /// Code background, chips, skeletons, thumbnail placeholders.
    static var ofCode: Color { ThemeRuntime.shared.colors.code }
    #if os(iOS)
    /// iPhone grouped cards (Settings, Sources) on ofSurface; 26pt corners (`Metrics.cardRadius`).
    static var ofCard: Color { ThemeRuntime.shared.colors.card }
    /// Inside a card: the search/paste field, the square behind a row's leading icon.
    static var ofCardInset: Color { ThemeRuntime.shared.colors.cardInset }
    /// The side drawer behind the Feed.
    static var ofDrawer: Color { ThemeRuntime.shared.colors.drawer }
    #endif
    /// The one accent: links, active tab, saved state, focus ring. The theme's, or Settings → Appearance → Accent color.
    static var ofAccent: Color { ThemeRuntime.shared.colors.accent }
    static let ofDanger = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let ofOK = Color(light: 0x34C759, dark: 0x30D158)
}

extension ShapeStyle where Self == Color {
    static var ofGround: Color { Color.ofGround }
    static var ofSidebarGround: Color { Color.ofSidebarGround }
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
    static var ofRead: Color { Color.ofRead }
    static var ofBorder: Color { Color.ofBorder }
    static var ofHairline: Color { Color.ofHairline }
    static var ofScroller: Color { Color.ofScroller }
    static var ofField: Color { Color.ofField }
    static var ofCode: Color { Color.ofCode }
    static var ofAccent: Color { Color.ofAccent }
    static var ofDanger: Color { Color.ofDanger }
    static var ofOK: Color { Color.ofOK }
    #if os(iOS)
    static var ofCard: Color { Color.ofCard }
    static var ofCardInset: Color { Color.ofCardInset }
    static var ofDrawer: Color { Color.ofDrawer }
    #endif
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
    /// A video reader narrower than this tightens its layout (`ReaderVideoBody`), with this side padding.
    static let narrowVideoReader: CGFloat = 360
    static let readerPaddingNarrow: CGFloat = 12
    /// Theater layout: the player is at least as wide as `theaterMaxWidth` allows, and grows past it to as tall
    /// as the reader less `theaterTitleRoom`, so the title row shows under it. Once the reader scrolls past
    /// `theaterSnapScroll`, the pinned player shrinks to `theaterPinnedShare` of the reader's height (at least
    /// `theaterPinnedMin` tall), and grows back at the top.
    static let theaterMaxWidth: CGFloat = 960
    static let theaterTitleRoom: CGFloat = 120
    static let theaterPinnedShare: CGFloat = 0.45
    static let theaterPinnedMin: CGFloat = 180
    static let theaterSnapScroll: CGFloat = 24
    /// A Short's 9:16 player is as tall as the reader less `verticalVideoTitleRoom`, so the title shows
    /// under it, but never narrower than 300pt (533pt tall), the least that fits the player's control bar.
    static let verticalVideoTitleRoom: CGFloat = 120
    static let verticalVideoMinWidth: CGFloat = 300
    /// Desktop list/reader header height.
    static let desktopHeaderHeight: CGFloat = 54
    /// Desktop icon buttons 30pt; phone touch targets 44pt.
    static let desktopIconButton: CGFloat = 30
    /// Reader toolbar actions on desktop: 28pt boxes 4pt apart, glyphs at 15pt, one grey (like Claude's bar).
    static let readerActionButton: CGFloat = 28
    static let readerActionSpacing: CGFloat = 4
    static let readerActionGlyph: CGFloat = 15
    static let touchTarget: CGFloat = 44
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

    // iPhone rows: headline first, more air than the desktop list.
    /// Row padding inside the list's 8pt inset (20pt from the screen edge); the hairline is inset the same.
    static let phoneRowPaddingH: CGFloat = 12
    static let phoneRowPaddingV: CGFloat = 18
    /// Square thumbnail beside the headline, and the corner radius of the full-width video frame.
    static let phoneThumb: CGFloat = 80
    static let phoneThumbRadius: CGFloat = 10
    static let phoneVideoRadius: CGFloat = 14
    /// iPhone grouped cards (Settings, Sources).
    static let cardRadius: CGFloat = 26
}
