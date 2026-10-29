import SwiftUI

/// Settings → Appearance → App Icon: the designs as icons in the chosen colorway, then the colorways as the
/// chosen design. `AppIconStore` (model.appIcon) keeps the choice and applies it.
struct SettingsAppIconSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        let choice = model.appIcon.choice
        #if os(macOS)
        let footer: String? = "Shown in the Dock while OpenDispatch is open."
        #else
        let footer: String? = nil
        #endif
        SettingsSection(title: "App Icon", footer: footer) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 72 : 76), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(AppIconDesign.allCases) { design in
                    AppIconTile(choice: AppIconChoice(design: design, colorway: choice.colorway), size: compact ? 56 : 52,
                                label: design.label, selected: design == choice.design) {
                        model.appIcon.select(AppIconChoice(design: design, colorway: choice.colorway))
                    }
                }
            }
            .padding(.vertical, 14)
            SettingsRow(label: "Colorway", hint: choice.colorway.label, stacked: compact) {
                HStack(spacing: compact ? 3 : 4) {
                    ForEach(AppIconColorway.allCases) { colorway in
                        AppIconTile(choice: AppIconChoice(design: choice.design, colorway: colorway), size: compact ? 24 : 22,
                                    label: nil, selected: colorway == choice.colorway) {
                            model.appIcon.select(AppIconChoice(design: choice.design, colorway: colorway))
                        }
                        .help(colorway.label)
                        .accessibilityLabel(colorway.label)
                    }
                }
            }
        }
    }
}

/// An app icon with its rounded corners, a ring around the selected one, and an optional name under it.
private struct AppIconTile: View {
    let choice: AppIconChoice
    let size: CGFloat
    let label: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        let corner = size * 0.2237
        Button(action: action) {
            VStack(spacing: 6) {
                choice.image
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                            .strokeBorder(selected ? Color.ofInk.opacity(0.55) : Color.clear, lineWidth: size < 40 ? 2 : 2.5)
                    }
                if let label {
                    Text(label)
                        .font(OFFont.ui(compact ? 13 : 11.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? choice.colorway.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
