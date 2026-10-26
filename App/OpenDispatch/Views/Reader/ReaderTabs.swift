import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One reader pane: the active tab's item, or the empty state. In split view a click anywhere in the
/// pane (the article's web view included) focuses it, so the list and j/k act on it.
struct ReaderPaneView: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let item = model.activeItem(inPane: pane) {
                ReaderItemView(item: item, pane: pane)
                    .id(item.id)
            } else {
                ReaderEmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ofSurface)
        #if os(macOS)
        .background {
            if model.isSplit { PaneMouseDownProbe { model.focusPane(pane) } }
        }
        #else
        .simultaneousGesture(TapGesture().onEnded { if model.isSplit { model.focusPane(pane) } })
        #endif
    }
}

/// Split view: two panes with a draggable hairline between them (double-click it to even them out).
struct ReaderSplitView: View {
    @Environment(AppModel.self) private var model

    /// The narrowest a pane gets from dragging the divider.
    private static let paneMinWidth: CGFloat = 300
    private static let space = "reader-split"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ReaderPaneView(pane: 0)
                    .frame(width: (width * model.splitFraction).rounded())
                divider(width: width)
                ReaderPaneView(pane: 1)
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    private func divider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.ofHairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(.columnResize)
                    #endif
                    .onTapGesture(count: 2) { model.splitFraction = 0.5 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { value in
                                let least = min(0.5, Self.paneMinWidth / max(width, 1))
                                model.splitFraction = min(max(value.location.x / width, least), 1 - least)
                            }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The reader bar's tabs, shown once a pane has more than one: badge and title, the active tab on the
/// selection grey, × on the active or hovered tab. Tabs share the width up to 196pt each.
struct ReaderTabStrip: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?

    var body: some View {
        let p = model.panes.indices.contains(pane) ? model.panes[pane] : ReaderPane()
        HStack(spacing: 2) {
            ForEach(Array(p.tabs.enumerated()), id: \.element.id) { index, tab in
                let quiet = { (i: Int) in i != p.active && p.tabs[i].id != hovered }
                tabView(tab, index: index, count: p.tabs.count, active: index == p.active,
                        divider: index > 0 && quiet(index) && quiet(index - 1))
            }
        }
        .padding(.leading, -6)
    }

    private func tabView(_ tab: ReaderTab, index: Int, count: Int, active: Bool, divider: Bool) -> some View {
        let item = model.item(for: tab)
        let isHovered = hovered == tab.id
        let title = item?.item.title ?? "Nothing selected"
        return HStack(spacing: 7) {
            if let item {
                SourceBadge(host: item.source.host, title: item.source.title, size: 14)
            }
            Text(title)
                .font(OFFont.ui(13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.closeTab(pane: pane, index: index) } label: {
                OFIcon.close.image
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabCloseButtonStyle())
            .opacity(active || isHovered ? 1 : 0)
            .help("Close tab (⌘W)")
            .accessibilityLabel("Close tab")
        }
        .foregroundStyle(active ? Color.ofInk : Color.ofMuted)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 36, maxWidth: 196, minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(active ? Color.ofSelection : isHovered ? Color.ofHover : Color.clear)
        )
        .overlay(alignment: .leading) {
            if divider {
                Rectangle().fill(Color.ofHairline).frame(width: 1, height: 14).offset(x: -2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activateTab(pane: pane, index: index) }
        .onHover { inside in
            if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
        }
        .contextMenu {
            Button("Close Tab") { model.closeTab(pane: pane, index: index) }
            Button("Close Other Tabs") { model.closeOtherTabs(pane: pane, index: index) }
                .disabled(count < 2)
        }
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// The tab's ×: muted, ink on a border-grey square while hovered.
private struct TabCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabCloseButtonBody(configuration: configuration)
    }
}

private struct TabCloseButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Color.ofInk : Color.ofMuted)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Color.ofBorder : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

#if os(macOS)
/// Calls `onMouseDown` for every left click inside its frame, without taking the click: a background
/// view can't see clicks that land in the WKWebView above it, so it watches the window's events.
private struct PaneMouseDownProbe: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onMouseDown = onMouseDown
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.uninstall()
    }

    final class ProbeView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onMouseDown?()
                    }
                }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
