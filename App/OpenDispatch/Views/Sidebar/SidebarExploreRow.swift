import SwiftUI

/// The Explore row at the top of the sidebar: a compass and the name. It opens the New Tab page
/// (search for videos, podcasts and sources, or open a link) with its field focused. Looks like SidebarViewRow;
/// it is a way in, not a place the list shows, so it is never the selected row.
struct SidebarExploreRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("ph.explore")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .frame(width: SidebarStyle.iconColumn)
                Text("Explore")
                    .font(OFFont.sidebarRow)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.ofInk)
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .modifier(SidebarRowBackground(active: false, hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Explore")
        .accessibilityHint("Search videos, podcasts and sources")
    }
}
