import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One reader pane: the active tab's item, a new tab, or the empty state. In split view a click anywhere
/// in the pane (the article's web view included) focuses it, so the list and j/k act on it.
struct ReaderPaneView: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let item = model.activeItem(inPane: pane) {
                ReaderItemView(item: item, pane: pane)
                    .id(item.id)
            } else if model.panes.indices.contains(pane), model.panes[pane].activeTab.isNew {
                NewTabView(pane: pane)
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

/// A new tab (+ or ⌘T): the bar, then what to open in it, recently closed tabs and the latest saved
/// items. Opening anything, from here or the list, fills this tab.
struct NewTabView: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var saved: [FeedItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 4) {
                    Text("New Tab").font(OFFont.ui(15, .medium)).foregroundStyle(.ofInk)
                    Text("Pick an item from the list, or one below").font(OFFont.ui(13)).foregroundStyle(.ofMuted)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

                section("Recently closed", Array(model.closedItems.prefix(5)))
                section("Saved", saved)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .overlayScrollers()
        .safeAreaInset(edge: .top, spacing: 0) {
            ReaderBar(pane: pane) {
                if model.isSplit {
                    Button { model.closePane(pane) } label: { OFIcon.close.image }
                        .buttonStyle(ReaderIconButtonStyle(size: Metrics.readerActionButton, glyph: Metrics.readerActionGlyph))
                        .help("Close this pane")
                        .accessibilityLabel("Close pane")
                }
            }
        }
        .background(Color.ofSurface)
        .task { saved = (try? await model.database.items(ItemQuery(view: .saved, limit: 5)).items) ?? [] }
    }

    @ViewBuilder private func section(_ title: String, _ items: [FeedItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .padding(.leading, 8)
                    .padding(.bottom, 4)
                ForEach(items, id: \.id) { item in
                    NewTabRow(item: item) {
                        model.focusPane(pane)
                        model.open(item)
                    }
                }
            }
        }
    }
}

/// An item on the new tab: badge, title, source muted on the right; the hover grey under the pointer.
private struct NewTabRow: View {
    let item: FeedItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SourceBadge(host: item.source.host, title: item.source.title, size: 16)
                Text(item.item.title)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.source.title)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(OFFont.ui(13))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(hovering ? Color.ofHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.item.title)
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

/// The reader's top row on macOS / iPad: the pane's tabs, then `actions`. Split view underlines the
/// focused pane's bar in the accent.
struct ReaderBar<Actions: View>: View {
    let pane: Int
    @ViewBuilder var actions: Actions
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ReaderTabStrip(pane: pane)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 16)
        #if os(macOS)
        // The top row shared with the list header and traffic lights, hairline under it like Claude's bar.
        .frame(height: Metrics.topBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
        #else
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.desktopHeaderHeight)
        #endif
        .overlay(alignment: .bottom) {
            if model.isSplit && model.focusedPane == pane { Rectangle().fill(Color.ofAccent).frame(height: 2) }
        }
        .frostedBar()
    }

    /// macOS full-screen reader: the traffic lights sit over the bar's leading edge (the left pane's).
    private var leadingInset: CGFloat {
        #if os(macOS)
        model.isFocused && pane == 0 ? Metrics.trafficLightInset : 16
        #else
        16
        #endif
    }
}

/// The reader bar's tabs, shown even when there's only one: pinned tabs first as 32pt source badges,
/// a hairline, then badge and title, the active tab on the selection grey, × on the active or hovered
/// tab, then + for a new tab. Unpinned tabs share the width up to 196pt each.
struct ReaderTabStrip: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?

    var body: some View {
        let p = model.panes.indices.contains(pane) ? model.panes[pane] : ReaderPane()
        HStack(spacing: 2) {
            ForEach(Array(p.tabs.enumerated()), id: \.element.id) { index, tab in
                let quiet = { (i: Int) in i != p.active && p.tabs[i].id != hovered }
                // The hairline after the pins stays put; between tabs it hides beside the active or hovered one.
                let afterPins = index > 0 && index == p.pinnedCount
                tabView(tab, index: index, count: p.tabs.count, active: index == p.active,
                        divider: afterPins || (index > 0 && quiet(index) && quiet(index - 1)))
            }
            Button { model.focusPane(pane); model.openNewTab() } label: {
                OFIcon.plus.image
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NewTabButtonStyle())
            .help("New tab (⌘T)")
            .accessibilityLabel("New tab")
        }
        .padding(.leading, -6)
    }

    private func tabView(_ tab: ReaderTab, index: Int, count: Int, active: Bool, divider: Bool) -> some View {
        let item = model.item(for: tab)
        let isHovered = hovered == tab.id
        let title = tab.isNew ? "New Tab" : item?.item.title ?? "Nothing selected"
        // The window's only tab, already empty, has nothing to close.
        let closable = count > 1 || model.isSplit || !tab.isNew
        return Group {
            if tab.isPinned {
                Group {
                    if let item { SourceBadge(host: item.source.host, title: item.source.title, size: 14) }
                }
                .frame(width: 32, height: 28)
            } else {
                HStack(spacing: 7) {
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
                    .opacity(closable && (active || isHovered) ? 1 : 0)
                    .disabled(!closable)
                    .help("Close tab (⌘W)")
                    .accessibilityLabel("Close tab")
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(minWidth: 36, maxWidth: 196, minHeight: 28, maxHeight: 28)
            }
        }
        .foregroundStyle(active ? Color.ofInk : Color.ofMuted)
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
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePinned(pane: pane, index: index) }
                .disabled(item == nil)
            Divider()
            Button("Close Tab") { model.closeTab(pane: pane, index: index) }
            Button("Close Other Tabs") { model.closeOtherTabs(pane: pane, index: index) }
                .disabled(count < 2)
        }
        .help(tab.isPinned ? "Pinned: \(title)" : title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isPinned ? "Pinned: \(title)" : title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// The strip's +: muted, ink on the hover grey while hovered, like an inactive tab.
private struct NewTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NewTabButtonBody(configuration: configuration)
    }
}

private struct NewTabButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Color.ofInk : Color.ofMuted)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color.ofSelection : hovering ? Color.ofHover : Color.clear)
            )
            .onHover { hovering = $0 }
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
