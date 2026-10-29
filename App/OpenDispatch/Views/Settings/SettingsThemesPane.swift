import SwiftUI

/// Themes pane: a theme for light mode and one for dark, each picked from cards (your own, Default, the
/// built-ins). Your own theme starts as a copy of the one in use and is changed with the color wells under it.
/// The choice syncs with the other settings; ThemeRuntime recolors the app and the reader page follows.
struct SettingsThemesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Themes", hint: "One theme for light mode and one for dark. The accent can be changed in Appearance.")
            mode(dark: false)
            mode(dark: true)
        }
    }

    private func mode(dark: Bool) -> some View {
        let active = (colorScheme == .dark) == dark
        let chosen = model.settings.theme(dark: dark)
        return SettingsSection(title: (dark ? "Dark Mode" : "Light Mode") + (active ? " \u{2014} Active" : "")) {
            ThemeCardRow(dark: dark, chosen: chosen.id) { id in select(id, dark: dark) } onNew: { makeCustom(dark: dark) }
            if chosen.id == AppTheme.customID, model.settings.customBase(dark: dark) != nil {
                CustomThemeEditor(dark: dark)
            }
        }
    }

    private func select(_ id: String, dark: Bool) {
        if dark { model.settings.darkTheme = id } else { model.settings.lightTheme = id }
    }

    /// Your own theme for the mode, as a copy of the one in use, and chosen.
    private func makeCustom(dark: Bool) {
        let base = model.settings.theme(dark: dark).base
        if dark { model.settings.customDarkTheme = base } else { model.settings.customLightTheme = base }
        select(AppTheme.customID, dark: dark)
    }
}

extension AppSettings {
    func customBase(dark: Bool) -> ThemeBase? { dark ? customDarkTheme : customLightTheme }
}

/// The mode's themes as cards in a row that scrolls sideways: Custom, Default, then the built-ins.
private struct ThemeCardRow: View {
    let dark: Bool
    let chosen: String
    let select: (String) -> Void
    let onNew: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        let builtIns = AppTheme.builtIns(dark: dark)
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                group("Custom") {
                    if let base = model.settings.customBase(dark: dark) {
                        card(AppTheme(id: AppTheme.customID, name: dark ? "My Dark" : "My Light", isDark: dark, base: base))
                    } else {
                        Button(action: onNew) {
                            VStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.ofBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .overlay { Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(.ofMuted) }
                                    .frame(width: ThemeCard.width, height: ThemeCard.height)
                                    .padding(3)
                                Text("New").font(OFFont.ui(compact ? 14 : 12)).foregroundStyle(.ofMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New \(dark ? "dark" : "light") theme")
                    }
                }
                divider
                group("Default") { card(builtIns[0]) }
                divider
                group("Built-in") {
                    ForEach(builtIns.dropFirst()) { card($0) }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, compact ? 0 : 2)
        }
        // The chosen theme in view, when it is one of the built-ins further along.
        .onAppear { proxy.scrollTo(chosen, anchor: .center) }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(OFFont.ui(compact ? 13.5 : 11.5))
                .foregroundStyle(.ofMuted)
                .padding(.leading, 3)
            HStack(alignment: .top, spacing: 10) { content() }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.ofHairline).frame(width: 1, height: ThemeCard.height - 16).padding(.top, 30)
    }

    private func card(_ theme: AppTheme) -> some View {
        ThemeCard(theme: theme, palette: theme.palette, selected: chosen == theme.id) { select(theme.id) }
            .id(theme.id)
    }
}

/// A theme as a card in its own colors: "Aa" in the text color over two lines, an accent chip, and its palette.
private struct ThemeCard: View {
    let theme: AppTheme
    let palette: ThemePalette
    let selected: Bool
    let action: () -> Void
    @Environment(\.settingsCompact) private var compact

    static let width: CGFloat = 116
    static let height: CGFloat = 74

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Aa")
                            .font(.system(size: 22, weight: .semibold, design: .serif))
                            .foregroundStyle(Color(hex: palette.ink))
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(Color(hex: palette.ink).opacity(0.6)).frame(height: 3)
                            Capsule().fill(Color(hex: palette.muted).opacity(0.5)).frame(width: 22, height: 3)
                        }
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(hex: palette.accent))
                            .frame(width: 14, height: 14)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: -3) {
                        ForEach(Array([palette.ground, palette.muted, palette.ink, palette.accent, palette.body].enumerated()), id: \.offset) { _, hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 13, height: 13)
                                .overlay { Circle().strokeBorder(Color(hex: palette.surface), lineWidth: 1.5) }
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .frame(width: Self.width, height: Self.height, alignment: .topLeading)
                .background(Color(hex: palette.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(selected ? Color.ofInk.opacity(0.5) : Color.clear, lineWidth: 2.5)
                }
                Text(theme.name)
                    .font(OFFont.ui(compact ? 14 : 12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The color wells for your own theme, and Delete.
private struct CustomThemeEditor: View {
    let dark: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    private static let fields: [(WritableKeyPath<ThemeBase, UInt32>, String)] = [
        (\.ground, "Sidebar"), (\.surface, "Background"), (\.ink, "Text"), (\.muted, "Secondary text"), (\.accent, "Accent"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 140), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Self.fields, id: \.1) { field in
                    ColorPicker(selection: binding(field.0), supportsOpacity: false) {
                        Text(field.1).font(OFFont.ui(compact ? 16 : 13)).foregroundStyle(.ofInk)
                    }
                    .fixedSize()
                }
            }
            HStack {
                Text("Changes apply as you pick. The rest of the palette is mixed from these.")
                    .font(OFFont.ui(compact ? 13.5 : 12))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Delete Theme", role: .destructive, action: delete)
                    .buttonStyle(SettingsSmallButtonStyle())
            }
        }
        .padding(.vertical, 12)
    }

    private func binding(_ key: WritableKeyPath<ThemeBase, UInt32>) -> Binding<Color> {
        Binding {
            Color(hex: model.settings.customBase(dark: dark)?[keyPath: key] ?? 0)
        } set: { color in
            guard let hex = color.srgbHex, var base = model.settings.customBase(dark: dark) else { return }
            base[keyPath: key] = hex
            if dark { model.settings.customDarkTheme = base } else { model.settings.customLightTheme = base }
        }
    }

    /// Back to Default, and your theme gone.
    private func delete() {
        if dark {
            model.settings.darkTheme = AppTheme.defaultID
            model.settings.customDarkTheme = nil
        } else {
            model.settings.lightTheme = AppTheme.defaultID
            model.settings.customLightTheme = nil
        }
    }
}

extension Color {
    /// The color as sRGB hex (alpha dropped); nil if it can't be read as sRGB.
    var srgbHex: UInt32? {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        func ch(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return ch(r) << 16 | ch(g) << 8 | ch(b)
    }
}
