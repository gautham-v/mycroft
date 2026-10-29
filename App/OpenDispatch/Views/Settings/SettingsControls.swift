import SwiftUI

// Shared controls for the Settings panes: PaneHeading, SettingRow, Segmented and the pane buttons
// from src/components/settings-dialog.tsx. Phones get 44pt targets (the web's max-md:h-11), and their
// panes sit on the warm ground as white grouped cards (SettingsCard) with monochrome inset controls.
// On the Mac and iPad a card is a bordered rounded panel a shade off the pane, with a hairline between
// its rows, under a section title (SettingsSectionLabel), like System Settings.

/// True on iPhone-width layouts. macOS is always regular.
struct SettingsCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by SettingsView; panes read it to size controls for touch.
    var settingsCompact: Bool {
        get { self[SettingsCompactKey.self] }
        set { self[SettingsCompactKey.self] = newValue }
    }
}

extension Color {
    /// A card's fill on the Mac and iPad: the pane's color a step toward the text.
    static var ofSettingsCard: Color { .ofHover }

    /// The fill of a control inside a phone card (segmented track, buttons, fields); code gray elsewhere.
    static var ofSettingsInset: Color {
        #if os(iOS)
        .ofCardInset
        #else
        .ofCode
        #endif
    }
}

/// Set inside a `SettingsCard` on phones: the card draws the dividers between its rows.
private struct SettingsInCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsInCard: Bool {
        get { self[SettingsInCardKey.self] }
        set { self[SettingsInCardKey.self] = newValue }
    }
}

/// Groups a pane's rows. On a phone: one white card (26pt corners) with a hairline between rows,
/// inset 20pt like the rows, and 22pt below it. Elsewhere: the rows as they were, each with its own
/// hairline on top.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        #if os(iOS)
        if compact {
            GroupedCard(content: content)
                .environment(\.settingsInCard, true)
                .padding(.bottom, 22)
        } else {
            SettingsPanelCard(content: content).padding(.bottom, 22)
        }
        #else
        SettingsPanelCard(content: content).padding(.bottom, 22)
        #endif
    }
}

/// The Mac and iPad card: rows 14pt from the sides with a hairline between them, on a bordered rounded panel.
struct SettingsPanelCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews.indices, id: \.self) { i in
                    if i > 0 { SettingsHairline() }
                    subviews[i]
                }
            }
        }
        .environment(\.settingsInCard, true)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPanelChrome()
    }
}

extension View {
    /// The Mac and iPad card's panel: card fill, 10pt corners, a hairline border.
    func settingsPanelChrome() -> some View {
        background(Color.ofSettingsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ofHairline, lineWidth: 1))
    }
}

/// A titled group of rows: the section title, the card, and an optional note under it.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    SettingsSectionLabel(text: title)
                    accessory()
                        .padding(.trailing, compact ? 20 : 4)
                        .padding(.bottom, compact ? 8 : 8)
                }
            }
            SettingsCard(content: content)
            if let footer {
                Text(footer)
                    .font(OFFont.ui(compact ? 13.5 : 12))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, compact ? 20 : 14)
                    .padding(.top, -14)
                    .padding(.bottom, 22)
            }
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(title: String?, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// Phone card chrome for content that lays itself out (a section with its own field and buttons):
    /// the white rounded card, 20pt of side padding and 22pt below. Elsewhere, 12pt above and below and
    /// a hairline on top, which is how those sections always looked.
    func settingsSectionChrome() -> some View { modifier(SettingsSectionChrome()) }

    fileprivate func settingsCardChrome() -> some View {
        modifier(SettingsCardChrome())
    }

    /// The hairline on top of a row outside a phone card (inside one, the card draws the dividers).
    func settingsTopHairline() -> some View { modifier(SettingsTopHairline()) }
}

private struct SettingsCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .background(Color.ofCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            #endif
            .padding(.bottom, 22)
    }
}

private struct SettingsSectionChrome: ViewModifier {
    @Environment(\.settingsCompact) private var compact

    func body(content: Content) -> some View {
        if compact {
            content.environment(\.settingsInCard, false).settingsCardChrome()
        } else {
            content
                .environment(\.settingsInCard, false)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsPanelChrome()
                .padding(.bottom, 22)
        }
    }
}

private struct SettingsTopHairline: ViewModifier {
    @Environment(\.settingsCompact) private var compact
    @Environment(\.settingsInCard) private var inCard

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) { if !inCard { SettingsHairline() } }
    }
}

/// A pane's one-line hint. The title shows in the navigation bar on phones and in the band above the pane elsewhere.
struct SettingsPaneHeading: View {
    let title: String
    let hint: String
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        Text(hint)
            .font(OFFont.ui(compact ? 14 : 13))
            .foregroundStyle(.ofMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, compact ? 18 : 16)
            .padding(.horizontal, compact ? 20 : 14)
            .accessibilityLabel("\(title). \(hint)")
    }
}

/// Section title above a card (folder names in Sources, groups in Shortcuts): 13/600 ink, in line with the
/// card's rows. On a phone it is the 15/500 muted label above a card.
struct SettingsSectionLabel: View {
    let text: String
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        Text(text)
            .font(compact ? OFFont.ui(15, .medium) : OFFont.ui(13, .semibold))
            .foregroundStyle(compact ? Color.ofMuted : Color.ofInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 20 : 14)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A settings row: label (and optional hint) on the left, a control on the right, hairline on top
/// (inside a phone `SettingsCard` the card draws it). `stacked` puts the control under the label instead, for controls too wide to share a phone's row;
/// it gets the row's width to fit in (a long label truncates) instead of its ideal size.
struct SettingsRow<Control: View>: View {
    let label: String
    var hint: String?
    var stacked = false
    /// A color chip before the label (SponsorBlock's category colors).
    var swatch: Color?
    @ViewBuilder var control: () -> Control
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(swatch)
                        .frame(width: 12, height: 12)
                        .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.18)) }
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(OFFont.ui(compact ? 17 : 14))
                        .foregroundStyle(.ofInk)
                    if let hint {
                        Text(hint)
                            .font(OFFont.ui(compact ? 13.5 : 12))
                            .foregroundStyle(.ofMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if stacked {
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                control()
                    .fixedSize()
            }
        }
        .padding(.vertical, compact ? 12 : 10)
        .frame(minHeight: compact ? 54 : 52)
        .settingsTopHairline()
        .accessibilityElement(children: .contain)
    }
}

/// 1pt divider in the hairline color.
struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(Color.ofHairline).frame(height: 1)
    }
}

/// Segmented radio group (Segmented in settings-dialog.tsx): code-colored track, the selected
/// option on a surface chip with a light shadow.
struct SettingsSegmented<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(OFFont.ui(compact ? 14 : 13, .medium))
                        .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 40, minHeight: compact ? 36 : 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: compact ? 9 : 4, style: .continuous)
                                    .fill(chip)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 6, style: .continuous).fill(compact ? Color.ofSettingsInset : Color.ofSelection))
        .animation(.easeOut(duration: 0.12), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The selected option's chip: the card's white on a phone, where the track is the inset gray.
    private var chip: Color {
        #if os(iOS)
        compact ? Color(light: 0xFFFFFF, dark: 0x4A4A46) : .ofSurface
        #else
        .ofSurface
        #endif
    }
}

/// PANE_BUTTON: filled code-colored pill, 13/500. `tint` colors the label (accent for "Add source").
struct SettingsPaneButtonStyle: ButtonStyle {
    var tint: Color = .ofInk
    @Environment(\.settingsCompact) private var compact
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OFFont.ui(compact ? 15 : 13, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 16 : 12)
            .frame(minHeight: compact ? 40 : 32)
            .background(
                RoundedRectangle(cornerRadius: compact ? 14 : 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.ofHover : (compact ? Color.ofSettingsInset : Color.ofCode))
            )
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Rectangle())
    }
}

/// SMALL_BUTTON: bordered, 13/500 ink. With `quiet`, borderless muted text (Remove / Keep links).
struct SettingsSmallButtonStyle: ButtonStyle {
    var quiet = false
    var fill: Color?
    @Environment(\.settingsCompact) private var compact
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OFFont.ui(compact ? 15 : 13, .medium))
            .foregroundStyle(fill != nil ? Color.white : (quiet ? Color.ofMuted : Color.ofInk))
            .lineLimit(1)
            .padding(.horizontal, quiet ? 10 : (compact ? 16 : 12))
            .frame(minHeight: compact ? 40 : 28)
            .background {
                let shape = RoundedRectangle(cornerRadius: compact ? 14 : 6, style: .continuous)
                if let fill {
                    shape.fill(fill)
                } else if configuration.isPressed {
                    shape.fill(Color.ofHover)
                } else if compact && !quiet {
                    shape.fill(Color.ofSettingsInset)
                }
            }
            .overlay {
                if !quiet && fill == nil && !compact {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofBorder)
                }
            }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Rectangle())
    }
}

/// Primary (accent) button: the Integrations "Save".
struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.settingsCompact) private var compact
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OFFont.ui(compact ? 16 : 14, .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 22 : 16)
            .frame(minHeight: compact ? Metrics.touchTarget : 34)
            .background(RoundedRectangle(cornerRadius: compact ? 16 : 8, style: .continuous).fill(fill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(Rectangle())
    }

    /// Phones keep their controls monochrome: ink with the ground's color on it. Elsewhere, accent.
    private var fill: Color { compact ? .ofInk : .ofAccent }
    private var foreground: Color {
        #if os(iOS)
        compact ? .ofSurface : .white
        #else
        .white
        #endif
    }
}

/// INPUT: ground-filled field with a border that turns accent while focused.
struct SettingsFieldChrome: ViewModifier {
    var focused: Bool
    @Environment(\.settingsCompact) private var compact

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(OFFont.ui(compact ? 16 : 14))
            .foregroundStyle(.ofInk)
            .padding(.horizontal, compact ? 14 : 12)
            .frame(minHeight: compact ? 48 : 38)
            .background(RoundedRectangle(cornerRadius: compact ? 16 : 8, style: .continuous).fill(compact ? Color.ofSettingsInset : Color.ofGround))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 16 : 8, style: .continuous)
                    .strokeBorder(focused ? (compact ? Color.ofMuted : Color.ofAccent) : (compact ? Color.clear : Color.ofBorder))
            )
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}

extension View {
    func settingsFieldChrome(focused: Bool) -> some View { modifier(SettingsFieldChrome(focused: focused)) }
}
