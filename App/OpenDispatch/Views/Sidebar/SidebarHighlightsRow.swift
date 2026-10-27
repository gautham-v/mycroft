import SwiftUI

/// The Highlights row under Saved in the sidebar: the highlighter glyph and the name.
/// Looks like SidebarViewRow.
struct SidebarHighlightsRow: View {
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
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .modifier(SidebarRowBackground(active: active, hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Highlights")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
