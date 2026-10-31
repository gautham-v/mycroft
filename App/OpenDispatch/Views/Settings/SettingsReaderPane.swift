import OpenDispatchCore
import SwiftUI

/// Reader pane: the article's font, size, spacing and width with a live sample, the color of new highlights,
/// how links look, and comments.
struct SettingsReaderPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Reader", hint: "How articles read, on this device.")
            SettingsSection(title: "Typography") {
                SettingsTextSizePreview(font: model.settings.readerFont, size: model.settings.textSize,
                                        leading: model.settings.lineSpacing, links: model.settings.linkStyle,
                                        highlight: model.settings.highlightColor)
                SettingsRow(label: "Font", hint: compact ? nil : "Headline and body in the article view", stacked: compact) {
                    SettingsSegmented(label: "Reader font", selection: $model.settings.readerFont,
                                      options: ReaderFontSetting.allCases.map { ($0, $0.label) })
                }
                SettingsRow(label: "Text size", hint: "\(OFFont.bodySize(model.settings.textSize).formatted()) pt") {
                    SettingsTextSizeStepper(size: $model.settings.textSize)
                }
                SettingsRow(label: "Line spacing") {
                    SettingsSegmented(label: "Line spacing", selection: $model.settings.lineSpacing,
                                      options: LineSpacingSetting.allCases.map { ($0, $0.label) })
                }
                if !compact {
                    SettingsRow(label: "Column width", hint: model.settings.fillWindow ? "Off while Fill window is on" : "Width of the article column") {
                        SettingsSegmented(label: "Column width", selection: $model.settings.readerWidth, options: [
                            (.narrow, "Narrow"), (.medium, "Medium"), (.wide, "Wide"),
                        ])
                        .disabled(model.settings.fillWindow)
                    }
                    SettingsRow(label: "Fill window", hint: "Use the whole reader pane") {
                        SettingsToggle(label: "Fill window", isOn: $model.settings.fillWindow)
                    }
                }
            }
            SettingsSection(title: "Highlights and Links") {
                SettingsRow(label: "Highlight color", hint: "For Add Note, and first in the menus", stacked: compact) {
                    HStack(spacing: compact ? 10 : 8) {
                        ForEach(HighlightColor.allCases) { color in
                            SettingsSwatch(label: color.title, selected: model.settings.highlightColor == color, size: compact ? 26 : 18) {
                                if color == .underline {
                                    Circle().fill(Color.ofCode).overlay {
                                        Text("A").font(.system(size: compact ? 13 : 10, weight: .semibold)).underline(color: color.swatch)
                                            .foregroundStyle(.ofInk)
                                    }
                                } else {
                                    Circle().fill(color.swatch)
                                }
                            } action: {
                                model.settings.highlightColor = color
                            }
                        }
                    }
                }
                SettingsRow(label: "Links") {
                    SettingsMenuPicker(label: "Links", selection: $model.settings.linkStyle,
                                       options: LinkStyleSetting.allCases.map { ($0, $0.label) })
                }
            }
            SettingsSection(title: "Discussion") {
                SettingsRow(label: "Show comments", hint: "Replies under posts, videos and articles") {
                    SettingsToggle(label: "Show comments", isOn: $model.settings.showComments)
                }
            }
        }
    }
}

/// Text size as steps: a smaller and a larger "A" around one dot per size, the current one and below filled.
struct SettingsTextSizeStepper: View {
    @Binding var size: TextSizeSetting
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        HStack(spacing: 2) {
            stepButton("Smaller text", glyph: 11, to: size.smaller)
            HStack(spacing: 5) {
                ForEach(TextSizeSetting.allCases) { step in
                    Circle()
                        .fill(step.rawValue == size.rawValue || isBelow(step) ? Color.ofInk : Color.ofBorder)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
            stepButton("Larger text", glyph: 16, to: size.larger)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 6, style: .continuous).fill(compact ? Color.ofSettingsInset : Color.ofCode))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
        .accessibilityValue(size.label)
    }

    private func isBelow(_ step: TextSizeSetting) -> Bool {
        let all = TextSizeSetting.allCases
        return (all.firstIndex(of: step) ?? 0) < (all.firstIndex(of: size) ?? 0)
    }

    private func stepButton(_ label: String, glyph: CGFloat, to next: TextSizeSetting?) -> some View {
        Button {
            if let next { size = next }
        } label: {
            Text("A")
                .font(OFFont.ui(glyph, .medium))
                .foregroundStyle(next == nil ? Color.ofFaint : Color.ofInk)
                .frame(width: compact ? 44 : 32, height: compact ? 40 : 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(next == nil)
        .accessibilityLabel(label)
    }
}

/// A sample of the reader headline and body at the chosen font, size and line spacing, with a highlight in the
/// default highlight color and a link in the chosen link style.
struct SettingsTextSizePreview: View {
    let font: ReaderFontSetting
    let size: TextSizeSetting
    let leading: LineSpacingSetting
    var links: LinkStyleSetting = .underlined
    var highlight: HighlightColor = .yellow
    @Environment(\.settingsCompact) private var compact

    private var sample: AttributedString {
        var text = AttributedString("Jumps over the lazy dog, as it has done in ")
        var marked = AttributedString("type specimens")
        if highlight == .underline {
            marked.underlineStyle = Text.LineStyle(pattern: .solid, color: highlight.swatch)
        } else {
            marked.backgroundColor = highlight.swatch.opacity(0.32)
        }
        var link = AttributedString("a century and more")
        link.foregroundColor = links == .plain ? Color.ofBody : Color.ofAccent
        if links != .accent { link.underlineStyle = Text.LineStyle(pattern: .solid, color: links == .plain ? Color.ofMuted : Color.ofAccent) }
        text.append(marked)
        text.append(AttributedString(" for "))
        text.append(link)
        text.append(AttributedString("."))
        return text
    }

    var body: some View {
        let headline = OFFont.headlineSize(size)
        let bodySize = OFFont.bodySize(size)
        VStack(alignment: .leading, spacing: 4) {
            Text("The quick brown fox")
                .font(OFFont.reader(font, headline, .semibold))
                .foregroundStyle(.ofInk)
            Text(sample)
                .font(OFFont.reader(font, bodySize))
                .foregroundStyle(.ofBody)
                .lineSpacing(bodySize * (leading.lineHeight - 1.2))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 16 : 8, style: .continuous).fill(compact ? Color.ofSettingsInset : Color.ofSurface))
        .padding(.vertical, 12)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.12), value: size)
        .animation(.easeOut(duration: 0.12), value: leading)
    }
}

