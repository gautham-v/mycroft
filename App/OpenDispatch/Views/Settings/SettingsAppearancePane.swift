import OpenDispatchCore
import SwiftUI

/// Appearance pane: the color scheme as pictures, the accent color, the app icon, and how lists look (density, thumbnails,
/// the unread marker, source icons, feed order, hiding read items), then keyboard shortcuts. Values live in `model.settings`
/// (AppSettings, JSON in UserDefaults "openfeed.settings"); RootView applies the scheme, ThemeRuntime the accent,
/// and list rows read the rest through `\.listLayout`.
struct SettingsAppearancePane: View {
    let onShowShortcuts: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Appearance", hint: "Applies on this device.")
            SettingsSection(title: "Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color scheme")
                        .font(OFFont.ui(compact ? 15 : 12))
                        .foregroundStyle(.ofMuted)
                    HStack(spacing: compact ? 10 : 16) {
                        ForEach([ThemeSetting.system, .light, .dark]) { scheme in
                            SchemeTile(scheme: scheme, selected: model.settings.theme == scheme) {
                                model.settings.theme = scheme
                            }
                        }
                    }
                }
                .padding(.vertical, 14)
                SettingsRow(label: "Accent color", hint: model.settings.accent == .theme ? "The theme\u{2019}s own" : nil,
                            stacked: compact) {
                    AccentPicker(selection: $model.settings.accent)
                }
            }
            SettingsAppIconSection()
            SettingsSection(title: "Lists") {
                SettingsRow(label: "Density") {
                    SettingsSegmented(label: "Density", selection: $model.settings.listDensity,
                                      options: ListDensitySetting.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Thumbnails") {
                    SettingsSegmented(label: "Thumbnails", selection: $model.settings.listThumbnails,
                                      options: ListThumbnailSetting.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Unread marker", hint: "How unread items stand out") {
                    SettingsMenuPicker(label: "Unread marker", selection: $model.settings.unreadMarker,
                                       options: UnreadMarkerSetting.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Source icons") {
                    SettingsSegmented(label: "Source icons", selection: $model.settings.sourceIcons,
                                      options: SourceIconSetting.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Feed order", hint: "Balanced keeps busy sources from filling the top") {
                    SettingsSegmented(label: "Feed order", selection: $model.settings.feedOrder,
                                      options: FeedOrder.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Hide read items", hint: "They stay in History") {
                    SettingsToggle(label: "Hide read items", isOn: $model.settings.hideReadItems)
                }
            }
            // Shortcuts need a hardware keyboard and the side-by-side layout, so not on phones.
            if !compact {
                SettingsSection(title: "Keyboard") {
                    SettingsRow(label: "Keyboard shortcuts", hint: "Or press ? anywhere") {
                        Button("Show", action: onShowShortcuts)
                            .buttonStyle(SettingsPaneButtonStyle())
                            .accessibilityLabel("Show keyboard shortcuts")
                    }
                }
            }
        }
    }
}

/// A color scheme as a picture: a small window, light, dark or split, on the accent.
private struct SchemeTile: View {
    let scheme: ThemeSetting
    let selected: Bool
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    LinearGradient(colors: [Color.ofAccent.opacity(0.75), Color.ofAccent], startPoint: .topLeading, endPoint: .bottomTrailing)
                    switch scheme {
                    case .light: window(model.settings.palette(dark: false))
                    case .dark: window(model.settings.palette(dark: true))
                    case .system:
                        ZStack {
                            window(model.settings.palette(dark: false))
                            window(model.settings.palette(dark: true)).mask(Diagonal())
                        }
                    }
                }
                .frame(width: compact ? 88 : 116, height: compact ? 60 : 74)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.ofInk.opacity(0.5) : Color.clear, lineWidth: 2.5)
                }
                Text(scheme == .system ? "Auto" : scheme.label)
                    .font(OFFont.ui(compact ? 14 : 12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scheme == .system ? "Auto" : scheme.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A window in a palette's colors: sidebar, title line and two text lines.
    private func window(_ p: ThemePalette) -> some View {
        HStack(spacing: 0) {
            Color(hex: p.ground).frame(width: 15)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: p.ink)).frame(width: 26, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: p.muted).opacity(0.6)).frame(width: 34, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: p.muted).opacity(0.6)).frame(width: 22, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: p.accent)).frame(width: 12, height: 3)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: p.surface))
        }
        .frame(width: compact ? 54 : 68, height: compact ? 38 : 46)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// The lower right half of a rectangle, for the Auto tile's dark side.
private struct Diagonal: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX * 0.62, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX * 0.38, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The accent colors as swatches; Theme is the color wheel.
private struct AccentPicker: View {
    @Binding var selection: AccentSetting
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        HStack(spacing: compact ? 7 : 8) {
            ForEach(AccentSetting.allCases) { accent in
                SettingsSwatch(label: accent.label, selected: selection == accent, size: compact ? 22 : 18) {
                    if let hex = accent.hex {
                        Circle().fill(Color(light: hex.light, dark: hex.dark))
                    } else {
                        Circle().fill(AngularGradient(colors: [0xFF453A, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x0A84FF, 0xBF5AF2, 0xFF453A].map { Color(hex: $0) }, center: .center))
                    }
                } action: {
                    selection = accent
                }
            }
        }
    }
}

/// A round color choice with a ring around the selected one.
struct SettingsSwatch<Fill: View>: View {
    let label: String
    let selected: Bool
    var size: CGFloat = 18
    @ViewBuilder var fill: () -> Fill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            fill()
                .frame(width: size, height: size)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
                .padding(3)
                .overlay { Circle().strokeBorder(selected ? Color.ofInk.opacity(0.55) : Color.clear, lineWidth: 2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A Settings switch: small on the Mac, in the OK green.
struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.ofOK)
            #if os(macOS)
            .controlSize(.small)
            #endif
    }
}

/// A pop-up menu of options, for choices too long for a segmented control.
struct SettingsMenuPicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.1).tag(option.0)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(.ofInk)
        .fixedSize()
    }
}

/// Playback pane (PlaybackPane): autoplay, theater layout, transcripts and videos that won't play here for YouTube sources,
/// then SponsorBlock and Read aloud.
struct SettingsPlaybackPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Playback", hint: "Video autoplay for YouTube sources and posts, layout for YouTube, and the voice for reading articles aloud.")
            SettingsCard {
                SettingsRow(label: "Autoplay on select", hint: "Start playing when you open a video") {
                    toggle("Autoplay on select", isOn: $model.settings.autoplay)
                }
                SettingsRow(label: "Theater layout", hint: "Full-width player above the title") {
                    toggle("Theater layout", isOn: $model.settings.theater)
                }
                SettingsRow(label: "Transcripts", hint: "Show a video's captions under it, following along as it plays") {
                    toggle("Transcripts", isOn: $model.settings.videoTranscript)
                }
                SettingsRow(label: "Videos that won\u{2019}t play here",
                            hint: "Some owners keep their videos out of other apps. Mark opens them on YouTube; Hide also leaves them out of your lists.",
                            stacked: compact) {
                    SettingsSegmented(label: "Videos that won\u{2019}t play here", selection: $model.settings.blockedVideoTreatment,
                                      options: BlockedVideoTreatment.allCases.map { ($0, $0.label) })
                }
            }
            SettingsSponsorBlockSection()
            SettingsReadAloudSection()
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.ofOK)
            #if os(macOS)
            .controlSize(.small)
            #endif
    }
}
