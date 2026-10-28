import SwiftUI

/// The History row after Highlights in the sidebar: a clock and the name. Looks like SidebarViewRow.
struct SidebarHistoryRow: View {
    let active: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OFIcon.history.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofInk)
                    .frame(width: SidebarStyle.iconColumn)
                Text("History")
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
        .accessibilityLabel("History")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
