import SwiftUI

/// The Highlights row under Saved in the sidebar: the highlighter glyph, the name, and how many
/// highlights there are, muted at the end. Looks like SidebarViewRow.
struct SidebarHighlightsRow: View {
    let count: Int
    let active: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OFIcon.highlighter.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofInk)
                    .frame(width: SidebarStyle.iconColumn)
                Text("Highlights")
                    .font(OFFont.sidebarRow)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .modifier(SidebarRowBackground(active: active, hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(count > 0 ? "Highlights, \(count)" : "Highlights")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
