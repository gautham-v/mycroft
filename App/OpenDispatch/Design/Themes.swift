import Foundation
import Observation
import SwiftUI

// Themes (Settings → Themes): one for light mode and one for dark, each a built-in or the user's own.
// A theme is five colors (`ThemeBase`); the rest of the palette is mixed from them (`ThemePalette`).
// The Default themes keep the app's original tokens exactly, per platform. `ThemeRuntime` holds the
// resolved colors the `of*` tokens in Tokens.swift read, so a view that uses a token re-renders when
// the theme or accent changes (Observation tracks the read).

/// The colors a theme is made of. Hex RGB.
struct ThemeBase: Codable, Equatable, Hashable, Sendable {
    /// Window and sidebar.
    var ground: UInt32
    /// Lists, the reader, cards.
    var surface: UInt32
    /// Titles and primary text.
    var ink: UInt32
    /// Secondary text and meta lines.
    var muted: UInt32
    var accent: UInt32
}

/// A theme as listed in Settings → Themes.
struct AppTheme: Identifiable, Equatable, Sendable {
    /// Stored in AppSettings (`lightTheme` / `darkTheme`); `custom` is the user's own.
    let id: String
    let name: String
    let isDark: Bool
    let base: ThemeBase

    static let defaultID = "default"
    static let customID = "custom"

    var palette: ThemePalette {
        id == Self.defaultID ? (isDark ? .defaultDark : .defaultLight) : ThemePalette(base: base, isDark: isDark)
    }

    static let light: [AppTheme] = [
        AppTheme(id: defaultID, name: "Default", isDark: false, base: ThemePalette.defaultLight.base),
        AppTheme(id: "newsprint", name: "Newsprint", isDark: false, base: ThemeBase(ground: 0xE7E6E1, surface: 0xF6F5F1, ink: 0x1F1E1C, muted: 0x6B6862, accent: 0xB5361F)),
        AppTheme(id: "sepia", name: "Sepia", isDark: false, base: ThemeBase(ground: 0xE6D9BF, surface: 0xF3EAD6, ink: 0x4A3A2C, muted: 0x85705C, accent: 0x9C5A2B)),
        AppTheme(id: "glacier", name: "Glacier", isDark: false, base: ThemeBase(ground: 0xE2E9F0, surface: 0xF5F8FB, ink: 0x17222D, muted: 0x5B6B7A, accent: 0x2A72B8)),
        AppTheme(id: "sage", name: "Sage", isDark: false, base: ThemeBase(ground: 0xE1E8DF, surface: 0xF2F5F0, ink: 0x1C281E, muted: 0x5D6B5F, accent: 0x3B7A4C)),
    ]

    static let dark: [AppTheme] = [
        AppTheme(id: defaultID, name: "Default", isDark: true, base: ThemePalette.defaultDark.base),
        AppTheme(id: "ink", name: "Ink", isDark: true, base: ThemeBase(ground: 0x121212, surface: 0x000000, ink: 0xEDEDED, muted: 0x8A8A8A, accent: 0x5E9EFF)),
        AppTheme(id: "midnight", name: "Midnight", isDark: true, base: ThemeBase(ground: 0x1A1F2C, surface: 0x11151E, ink: 0xE4E8F1, muted: 0x8B93A7, accent: 0x82A6FF)),
        AppTheme(id: "espresso", name: "Espresso", isDark: true, base: ThemeBase(ground: 0x2C241F, surface: 0x1D1814, ink: 0xF0E7DD, muted: 0xA89685, accent: 0xE0955A)),
        AppTheme(id: "forest", name: "Forest", isDark: true, base: ThemeBase(ground: 0x202822, surface: 0x151A16, ink: 0xE3ECE4, muted: 0x8FA193, accent: 0x7CC48E)),
    ]

    static func builtIns(dark: Bool) -> [AppTheme] { dark ? Self.dark : Self.light }
}

/// The accent color (Settings → Appearance): the theme's own, or one of eight.
enum AccentSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case theme, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var label: String { self == .theme ? "Theme" : rawValue.capitalized }

    /// Light and dark values; nil for `.theme`. Yellow and green are darkened in light mode so links stay readable on white.
    var hex: (light: UInt32, dark: UInt32)? {
        switch self {
        case .theme: nil
        case .blue: (0x007AFF, 0x0A84FF)
        case .purple: (0xAF52DE, 0xBF5AF2)
        case .pink: (0xFF2D55, 0xFF375F)
        case .red: (0xFF3B30, 0xFF453A)
        case .orange: (0xF08A00, 0xFF9F0A)
        case .yellow: (0xC69300, 0xFFD60A)
        case .green: (0x248A3D, 0x30D158)
        case .graphite: (0x6E6E73, 0x98989D)
        }
    }
}

/// Every themed token, as hex RGB.
struct ThemePalette: Equatable, Sendable {
    var ground, surface, selection, hover: UInt32
    var ink, body, muted, faint, read: UInt32
    var border, hairline, scroller, code: UInt32
    /// iPhone grouped cards, the field and icon square inside them, the side drawer.
    var card, cardInset, drawer: UInt32
    var accent: UInt32

    var base: ThemeBase { ThemeBase(ground: ground, surface: surface, ink: ink, muted: muted, accent: accent) }

    /// The app's original light tokens (globals.css :root). iOS has a warm off-white surface that white cards sit on.
    static let defaultLight: ThemePalette = {
        var p = ThemePalette(
            ground: 0xF2F2F4, surface: 0xFFFFFF, selection: 0xE8E8EC, hover: 0xF4F4F6,
            ink: 0x1D1D1F, body: 0x3A3A3C, muted: 0x5E5E63, faint: 0xAEAEB2, read: 0x8E8E93,
            border: 0xD2D2D7, hairline: 0xE5E5EA, scroller: 0xBDBDC2, code: 0xF0F0F3,
            card: 0xFFFFFF, cardInset: 0xEFEFEC, drawer: 0xEFEFEC, accent: 0x007AFF)
        #if os(iOS)
        p.surface = 0xF8F8F6
        p.hairline = 0xE4E4E0
        #endif
        return p
    }()

    /// The app's original dark tokens (globals.css dark block).
    static let defaultDark: ThemePalette = {
        var p = ThemePalette(
            ground: 0x2A2A2C, surface: 0x212121, selection: 0x383839, hover: 0x2C2C2D,
            ink: 0xF5F5F7, body: 0xD1D1D6, muted: 0xB4B4B4, faint: 0x636366, read: 0x8A8A8E,
            border: 0x454545, hairline: 0x373737, scroller: 0x767676, code: 0x2E2E30,
            card: 0x282826, cardInset: 0x343431, drawer: 0x232321, accent: 0x0A84FF)
        #if os(iOS)
        p.surface = 0x1C1C1B
        p.hairline = 0x34342F
        #endif
        return p
    }()

    init(ground: UInt32, surface: UInt32, selection: UInt32, hover: UInt32, ink: UInt32, body: UInt32, muted: UInt32,
         faint: UInt32, read: UInt32, border: UInt32, hairline: UInt32, scroller: UInt32, code: UInt32, card: UInt32,
         cardInset: UInt32, drawer: UInt32, accent: UInt32) {
        self.ground = ground; self.surface = surface; self.selection = selection; self.hover = hover
        self.ink = ink; self.body = body; self.muted = muted; self.faint = faint; self.read = read
        self.border = border; self.hairline = hairline; self.scroller = scroller; self.code = code
        self.card = card; self.cardInset = cardInset; self.drawer = drawer; self.accent = accent
    }

    /// The rest of the palette mixed from a theme's five colors, at the ratios the Default tokens sit at.
    init(base b: ThemeBase, isDark: Bool) {
        let s = b.surface, i = b.ink
        let card = isDark ? Self.mix(s, i, 0.05) : Self.mix(s, 0xFFFFFF, 0.6)
        self.init(
            ground: b.ground, surface: s, selection: Self.mix(s, i, 0.09), hover: Self.mix(s, i, 0.045),
            ink: i, body: Self.mix(i, s, 0.13), muted: b.muted, faint: Self.mix(b.muted, s, 0.5), read: Self.mix(i, s, 0.45),
            border: Self.mix(s, i, 0.2), hairline: Self.mix(s, i, 0.1), scroller: Self.mix(s, i, 0.32), code: Self.mix(s, i, 0.06),
            card: card, cardInset: Self.mix(card, i, 0.06), drawer: b.ground, accent: b.accent)
    }

    /// `a` moved toward `b` by `t` (0...1), per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let v = ch(a, shift) + (ch(b, shift) - ch(a, shift)) * t
            out |= UInt32(max(0, min(255, v.rounded()))) << shift
        }
        return out
    }

    /// The reader page's variables for this palette (reader.css :root names).
    var readerCSS: String {
        let pairs: [(String, UInt32)] = [
            ("ground", ground), ("surface", surface), ("hover", hover), ("ink", ink), ("body", body), ("muted", muted),
            ("faint", faint), ("border", border), ("hairline", hairline), ("code", code), ("accent", accent),
        ]
        return pairs.map { "--\($0.0): \(Self.css($0.1));" }.joined(separator: " ")
    }

    static func css(_ hex: UInt32) -> String { String(format: "#%06x", hex) }
}

/// The light and dark palettes in use, as SwiftUI colors that resolve per appearance.
struct ThemeColors: Equatable {
    let light: ThemePalette
    let dark: ThemePalette
    /// Whether each mode is on its Default theme: the macOS sidebar lets its material show through those.
    let lightIsDefault: Bool
    let darkIsDefault: Bool

    let ground, surface, selection, hover, ink, body, muted, faint, read, border, hairline, scroller, code: Color
    let card, cardInset, drawer, accent, sidebarGround: Color
    /// iOS fields on the surface (the sidebar search box): white / 343436 on the Default themes.
    let field: Color

    init(light: ThemePalette, dark: ThemePalette, lightIsDefault: Bool = true, darkIsDefault: Bool = true) {
        self.light = light
        self.dark = dark
        self.lightIsDefault = lightIsDefault
        self.darkIsDefault = darkIsDefault
        func c(_ k: KeyPath<ThemePalette, UInt32>) -> Color { Color(light: light[keyPath: k], dark: dark[keyPath: k]) }
        ground = c(\.ground); surface = c(\.surface); selection = c(\.selection); hover = c(\.hover)
        ink = c(\.ink); body = c(\.body); muted = c(\.muted); faint = c(\.faint); read = c(\.read)
        border = c(\.border); hairline = c(\.hairline); scroller = c(\.scroller); code = c(\.code)
        card = c(\.card); cardInset = c(\.cardInset); drawer = c(\.drawer); accent = c(\.accent)
        sidebarGround = Color(light: light.ground, lightAlpha: lightIsDefault ? 0.45 : 0.92,
                              dark: dark.ground, darkAlpha: darkIsDefault ? 0.45 : 0.92)
        field = Color(light: lightIsDefault ? 0xFFFFFF : light.cardInset, dark: darkIsDefault ? 0x343436 : dark.cardInset)
    }

    static func == (a: ThemeColors, b: ThemeColors) -> Bool {
        a.light == b.light && a.dark == b.dark && a.lightIsDefault == b.lightIsDefault && a.darkIsDefault == b.darkIsDefault
    }
}

/// The resolved theme the tokens read. Set from AppSettings by AppModel (on launch and on every change,
/// iCloud's included); only touched on the main thread.
@Observable
final class ThemeRuntime: @unchecked Sendable {
    static let shared = ThemeRuntime()

    private(set) var colors = ThemeColors(light: .defaultLight, dark: .defaultDark)

    func apply(_ settings: AppSettings) {
        let next = ThemeColors(light: settings.palette(dark: false), dark: settings.palette(dark: true),
                               lightIsDefault: settings.isDefaultTheme(dark: false), darkIsDefault: settings.isDefaultTheme(dark: true))
        if next != colors { colors = next }
    }
}

extension AppSettings {
    /// The theme chosen for light or dark mode; the user's own when `custom` is chosen and set, else Default.
    func theme(dark: Bool) -> AppTheme {
        let id = dark ? darkTheme : lightTheme
        if id == AppTheme.customID, let base = dark ? customDarkTheme : customLightTheme {
            return AppTheme(id: AppTheme.customID, name: dark ? "My Dark" : "My Light", isDark: dark, base: base)
        }
        return AppTheme.builtIns(dark: dark).first { $0.id == id } ?? AppTheme.builtIns(dark: dark)[0]
    }

    /// The theme's palette with the accent setting applied.
    func palette(dark: Bool) -> ThemePalette {
        var p = theme(dark: dark).palette
        if let hex = accent.hex { p.accent = dark ? hex.dark : hex.light }
        return p
    }

    func isDefaultTheme(dark: Bool) -> Bool { theme(dark: dark).id == AppTheme.defaultID }

    /// CSS that recolors the reader page for the themes and accent (after reader.css, same selectors);
    /// nil when both modes are on Default with the theme's accent, so the page keeps its own values. On iOS the
    /// Default palette always goes in: its surface is off-white, and the page's white would show as a band behind
    /// the article, its edge right over a post's author row.
    var readerThemeCSS: String? {
        func vars(dark: Bool) -> String? {
            #if os(iOS)
            return palette(dark: dark).readerCSS
            #else
            if !isDefaultTheme(dark: dark) { return palette(dark: dark).readerCSS }
            guard accent != .theme else { return nil }
            return "--accent: \(ThemePalette.css(palette(dark: dark).accent));"
            #endif
        }
        let light = vars(dark: false), dark = vars(dark: true)
        guard light != nil || dark != nil else { return nil }
        var css = ""
        if let light { css += ":root { \(light) }\n" }
        if let dark {
            css += "@media (prefers-color-scheme: dark) { :root:not([data-theme=\"light\"]) { \(dark) } }\n"
            css += ":root[data-theme=\"dark\"] { \(dark) }\n"
        }
        return css
    }
}
