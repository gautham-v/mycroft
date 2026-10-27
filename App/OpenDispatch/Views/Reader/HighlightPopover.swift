import OpenDispatchCore
import SwiftUI

/// What a click on a highlight (or its note marker) offers, in a small popover under it, like Apple
/// Books: the five colors and Underline with the current one marked, a note button and a remove button,
/// and below them the note itself. Clicking the note opens the note sheet. Closes on Esc, on a click
/// outside, and when the reader scrolls (`ReaderArticleWebView`). On iPhone it is the same popover, kept
/// a popover rather than a sheet by `presentationCompactAdaptation`.
struct HighlightPopover: View {
    let id: String
    let pane: Int
    @Environment(HighlightStore.self) private var store

    var body: some View {
        Group {
            if let h = store.highlight(id: id) {
                content(h)
            } else {
                // Removed (here or on another device) while it was open.
                Color.clear.frame(width: 1, height: 1).onAppear { store.closePopover() }
            }
        }
        .frame(width: 272)
        .background(Color.ofSurface)
        .presentationCompactAdaptation(.popover)
    }

    private func content(_ h: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(HighlightColor.allCases) { color in
                    HighlightSwatchButton(color: color, selected: color == h.color) { store.setColor(h.id, color) }
                }
                Spacer(minLength: 4)
                actionButton(.note, label: h.note.isEmpty ? "Add note" : "Edit note") { store.editNote(h.id, pane: pane) }
                actionButton(.trash, label: "Remove highlight") {
                    store.closePopover()
                    store.remove(h.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(Color.ofHairline).frame(height: 1)
            Button { store.editNote(h.id, pane: pane) } label: {
                Text(h.note.isEmpty ? "Add a note\u{2026}" : h.note)
                    .font(OFFont.ui(13))
                    .foregroundStyle(h.note.isEmpty ? Color.ofMuted : Color.ofBody)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(h.note.isEmpty ? "Add a note" : "Note: \(h.note)")
        }
    }

    private func actionButton(_ icon: OFIcon, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.image
                .font(.system(size: 14))
                .foregroundStyle(Color.ofInk)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One color in the popover's row: a solid circle (an underlined A for Underline), ringed when it is the
/// highlight's color.
private struct HighlightSwatchButton: View {
    let color: HighlightColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if color == .underline {
                    Circle().fill(Color.ofCode)
                    VStack(spacing: 1) {
                        Text("A").font(OFFont.ui(11, .medium)).foregroundStyle(Color.ofInk)
                        Capsule().fill(color.swatch).frame(width: 10, height: 1.5)
                    }
                } else {
                    Circle().fill(color.swatch)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.ofInk.opacity(0.55) : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
