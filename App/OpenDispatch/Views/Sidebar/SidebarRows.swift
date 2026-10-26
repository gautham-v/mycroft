import OpenDispatchCore
import SwiftUI

/// Small building blocks of the desktop sidebar (sidebar.tsx ViewRow, FooterRow, InlineInput, ICON_BTN).
enum SidebarStyle {
    /// Folder header / "New folder" label: 13pt regular, like Claude's "Recents".
    static let sectionFont = OFFont.ui(13)
    static let sectionTracking: CGFloat = 0
    static let headerHeight: CGFloat = 26
    /// Row horizontal padding (px-2) and icon column width (w-[20px]).
    static let rowPadding: CGFloat = 8
    static let iconColumn: CGFloat = 20
}

/// Background for a sidebar row: nav selection when active, nav hover when hovered.
struct SidebarRowBackground: ViewModifier {
    var active: Bool
    var hovered: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(active ? Color.ofNavSelection : hovered ? Color.ofNavHover : Color.clear)
        )
    }
}

/// A 2pt accent line drawn at the top (or bottom) edge of a drop target, like the web's inset shadow.
struct SidebarDropIndicator: ViewModifier {
    var visible: Bool
    var edge: VerticalEdge = .top

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : .bottom) {
            if visible {
                Rectangle().fill(Color.ofAccent).frame(height: 2).allowsHitTesting(false)
            }
        }
    }
}

/// One of the six view rows (All, Saved, Articles, Posts, Video, Podcasts).
struct SidebarViewRow: View {
    let view: FeedView
    let active: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                view.icon.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofInk)
                    .frame(width: SidebarStyle.iconColumn)
                Text(view.title)
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
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Footer "Add source" row (13.5pt, ink).
struct SidebarFooterRow: View {
    let icon: OFIcon
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.image
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: SidebarStyle.iconColumn)
                Text(label).font(OFFont.sidebarFooter).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.ofInk)
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .modifier(SidebarRowBackground(active: false, hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Square icon button (header hide-sidebar, footer Settings): ink, nav hover background.
struct SidebarIconButton: View {
    let icon: OFIcon
    let label: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 15
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            icon.image
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(Color.ofInk)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? Color.ofNavHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The small muted icon button shown on hover inside rows and headers (MoreIcon, ChevronIcon).
struct SidebarMiniButtonLabel: View {
    let icon: OFIcon
    var size: CGFloat = 20
    var iconSize: CGFloat = 11
    var rotation: Angle = .zero
    @State private var hovered = false

    var body: some View {
        icon.image
            .font(.system(size: iconSize, weight: .semibold))
            .rotationEffect(rotation)
            .foregroundStyle(hovered ? Color.ofInk : Color.ofMuted)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(hovered ? Color.ofNavSelection : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// One-line text field for renaming or naming a new folder (InlineInput). Enter commits, Escape
/// cancels, losing focus commits. An unchanged or blank value cancels.
struct SidebarNameField: View {
    let initial: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var done = false
    @FocusState private var focused: Bool

    init(initial: String, placeholder: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.placeholder = placeholder
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofInk)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Color.ofSurface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).stroke(Color.ofAccent, lineWidth: 1))
            .focused($focused)
            .accessibilityLabel(placeholder)
            .onAppear { focused = true }
            .onSubmit(commit)
            .onKeyPress(.escape) {
                cancel()
                return .handled
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
    }

    private func commit() {
        guard !done else { return }
        done = true
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != initial { onCommit(t) } else { onCancel() }
    }

    private func cancel() {
        guard !done else { return }
        done = true
        onCancel()
    }
}
