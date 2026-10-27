import SwiftUI

// Shared controls for the Settings panes: PaneHeading, SettingRow, Segmented and the pane buttons
// from src/components/settings-dialog.tsx. Phones get 44pt targets (the web's max-md:h-11).

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

/// Pane title (hidden on phones, where the navigation title shows it) and a one-line hint.
struct SettingsPaneHeading: View {
    let title: String
    let hint: String
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !compact {
                Text(title)
                    .font(OFFont.ui(17, .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(.ofInk)
            }
            Text(hint)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .padding(.trailing, compact ? 0 : 40)
    }
}

/// Section label inside a pane (folder names in Sources, groups in Shortcuts): 11/600 faint.
struct SettingsSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OFFont.ui(11, .semibold))
            .tracking(0.11)
            .foregroundStyle(.ofFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
    }
}

/// A settings row: label (and optional hint) on the left, a control on the right, hairline on top.
/// `stacked` puts the control under the label instead, for controls too wide to share a phone's row;
/// it gets the row's width to fit in (a long label truncates) instead of its ideal size.
struct SettingsRow<Control: View>: View {
    let label: String
    var hint: String?
    var stacked = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(OFFont.ui(14))
                    .foregroundStyle(.ofInk)
                if let hint {
                    Text(hint)
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { SettingsHairline() }
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
                        .font(OFFont.ui(13, .medium))
                        .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 40, minHeight: compact ? 40 : 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.ofSurface)
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
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ofCode))
        .animation(.easeOut(duration: 0.12), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// PANE_BUTTON: filled code-colored pill, 13/500. `tint` colors the label (accent for "Add source").
struct SettingsPaneButtonStyle: ButtonStyle {
    var tint: Color = .ofInk
    @Environment(\.settingsCompact) private var compact
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OFFont.ui(13, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: compact ? Metrics.touchTarget : 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.ofHover : Color.ofCode)
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
            .font(OFFont.ui(13, .medium))
            .foregroundStyle(fill != nil ? Color.white : (quiet ? Color.ofMuted : Color.ofInk))
            .lineLimit(1)
            .padding(.horizontal, quiet ? 10 : 12)
            .frame(minHeight: compact ? Metrics.touchTarget : 28)
            .background {
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                if let fill {
                    shape.fill(fill)
                } else if configuration.isPressed {
                    shape.fill(Color.ofHover)
                }
            }
            .overlay {
                if !quiet && fill == nil {
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
            .font(OFFont.ui(14, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: compact ? Metrics.touchTarget : 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofAccent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

/// INPUT: ground-filled field with a border that turns accent while focused.
struct SettingsFieldChrome: ViewModifier {
    var focused: Bool
    @Environment(\.settingsCompact) private var compact

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(OFFont.ui(compact ? 15 : 14))
            .foregroundStyle(.ofInk)
            .padding(.horizontal, 12)
            .frame(minHeight: compact ? Metrics.touchTarget : 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.ofAccent : Color.ofBorder)
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
