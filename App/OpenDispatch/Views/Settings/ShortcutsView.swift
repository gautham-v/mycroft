import OpenDispatchCore
import SwiftUI

/// A shortcut as the help overlay shows it. `separator` reads between keys: "or" for alternatives,
/// "then" for a chord; nil means the keys are pressed together. (Shortcut in use-keyboard.ts.)
struct ShortcutEntry: Hashable, Sendable {
    let keys: [String]
    let label: String
    var separator: String?
}

struct ShortcutGroup: Hashable, Sendable {
    let title: String
    let items: [ShortcutEntry]
}

/// Keyboard shortcuts overlay (shortcuts-dialog.tsx), opened with "?", ⌘/ or Settings → Appearance.
/// Esc, "?" or the close button dismisses it.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    /// SHORTCUTS in use-keyboard.ts, in display order. Keep in step with Views/Feed/KeyboardShortcuts.swift.
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Items", items: [
            ShortcutEntry(keys: ["j", "↓"], label: "Next item", separator: "or"),
            ShortcutEntry(keys: ["k", "↑"], label: "Previous item", separator: "or"),
            ShortcutEntry(keys: ["o", "Enter"], label: "Open original in the browser", separator: "or"),
            ShortcutEntry(keys: ["s"], label: "Save or unsave"),
            ShortcutEntry(keys: ["⇧", "⌘", "R"], label: "Reload the article"),
        ]),
        ShortcutGroup(title: "Views", items: [
            ShortcutEntry(keys: ["g", "a"], label: "All", separator: "then"),
            ShortcutEntry(keys: ["g", "s"], label: "Saved", separator: "then"),
            ShortcutEntry(keys: ["g", "v"], label: "Video", separator: "then"),
            ShortcutEntry(keys: ["g", "p"], label: "Podcasts", separator: "then"),
        ]),
        ShortcutGroup(title: "Tabs and split view", items: [
            ShortcutEntry(keys: ["⌘", "click"], label: "Open in a new tab"),
            ShortcutEntry(keys: ["⌥", "click"], label: "Open in split view"),
            ShortcutEntry(keys: ["⇧", "⌘", "]"], label: "Next tab"),
            ShortcutEntry(keys: ["⇧", "⌘", "["], label: "Previous tab"),
            ShortcutEntry(keys: ["⌘", "T"], label: "New tab"),
            ShortcutEntry(keys: ["⌘", "W"], label: "Close the tab"),
            ShortcutEntry(keys: ["⇧", "⌘", "T"], label: "Reopen the last closed tab"),
            ShortcutEntry(keys: ["⌥", "⌘", "S"], label: "Split view on or off"),
        ]),
        ShortcutGroup(title: "App", items: [
            ShortcutEntry(keys: ["/"], label: "Search"),
            ShortcutEntry(keys: ["⌘", "K"], label: "Filter sources in the sidebar"),
            ShortcutEntry(keys: ["r"], label: "Refresh feeds"),
            ShortcutEntry(keys: ["⌘", "N"], label: "Add a source"),
            ShortcutEntry(keys: ["⌘", "\\"], label: "Show or hide the sidebar"),
            ShortcutEntry(keys: ["⇧", "⌘", "F"], label: "Full-screen reader"),
            ShortcutEntry(keys: ["Esc"], label: "Clear the source filter or search, or leave full screen"),
            ShortcutEntry(keys: ["?"], label: "Show these shortcuts"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard shortcuts")
                    .font(OFFont.ui(17, .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(.ofInk)
                    .padding(.trailing, 40)
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .font(OFFont.ui(11, .semibold))
                            .tracking(0.11)
                            .foregroundStyle(.ofFaint)
                            .padding(.bottom, 4)
                        ForEach(group.items, id: \.label) { entry in
                            row(entry)
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 420, maxWidth: 420)
        #if os(macOS)
        .frame(minHeight: 520)
        #endif
        .background(Color.ofSurface)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                OFIcon.close.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofMuted)
                    .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close keyboard shortcuts")
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress("?") {
            dismiss()
            return .handled
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func row(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.label)
                .font(OFFont.ui(14))
                .foregroundStyle(.ofInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(entry.keys.enumerated()), id: \.offset) { i, key in
                    if i > 0, let sep = entry.separator {
                        Text(sep)
                            .font(OFFont.ui(11))
                            .foregroundStyle(.ofFaint)
                    }
                    SettingsKeyCap(key: key)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { SettingsHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// `<kbd>`: 12pt key name on code background with a hairline border.
struct SettingsKeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(OFFont.ui(12))
            .foregroundStyle(.ofInk)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.ofCode))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.ofHairline))
    }
}

#Preview {
    ShortcutsView()
}
