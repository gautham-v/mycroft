import OpenDispatchCore
import SwiftUI

/// The "Topics" group in the Mac and iPad sidebar, after the view rows and before the sources: a header
/// with a + (New Topic…) and a row per topic with its keyword and unread count. A row's context menu (and
/// the "…" on hover) edits it, turns Notify on New Matches on or off, marks it read and removes it.
/// Shows only when there is at least one topic; the first is made from the Feed menu or Explore's Follow.
struct SidebarTopicsSection: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Source?
    @State private var errorMessage: String?

    var body: some View {
        let topics = model.topics
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(topics) { topic in
                    SidebarTopicRow(
                        topic: topic, active: model.selectedSourceID == topic.id, unread: model.topicStore.unreadCount(topic),
                        refreshing: model.topicStore.refreshing.contains(topic.id),
                        onOpen: { model.navigate(sourceID: topic.id) }
                    ) { menu(topic) }
                    .contextMenu { menu(topic) }
                }
            }
            .padding(.top, 12)
            .confirmationDialog(
                pendingDelete.map { "Remove \($0.title)?" } ?? "Remove topic?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { topic in
                Button("Remove", role: .destructive) { perform { try await model.deleteTopic(id: topic.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removing a topic also removes its items.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Topics")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button { model.beginNewTopic() } label: {
                SidebarMiniButtonLabel(icon: .plus, size: 20, iconSize: 11)
            }
            .buttonStyle(.plain)
            .help("New Topic\u{2026}")
            .accessibilityLabel("New Topic")
        }
        .font(SidebarStyle.sectionFont)
        .tracking(SidebarStyle.sectionTracking)
        .foregroundStyle(Color.ofMuted)
        .padding(.leading, SidebarStyle.rowPadding)
        .padding(.trailing, 4)
        .frame(height: SidebarStyle.headerHeight)
    }

    @ViewBuilder private func menu(_ topic: Source) -> some View {
        Button("Edit Topic\u{2026}") { model.beginEditTopic(topic) }
        Toggle("Notify on New Matches", isOn: Binding(
            get: { topic.notifies },
            set: { on in perform { try await model.setSourceNotify(id: topic.id, on: on) } }))
        Divider()
        Button("Mark All as Read") { model.markAllRead(topic: topic) }
        Divider()
        Button("Remove Topic\u{2026}", role: .destructive) { pendingDelete = topic }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = HTTP.message(error) }
        }
    }
}

/// A topic row: the "number" symbol in the icon column, the keyword, and the unread count (a spinner while
/// it searches, the "…" menu on hover).
private struct SidebarTopicRow<MenuContent: View>: View {
    let topic: Source
    let active: Bool
    let unread: Int
    let refreshing: Bool
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            OFIcon.topic.image
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.ofInk)
                .frame(width: SidebarStyle.iconColumn)
            Text(topic.title)
                .font(OFFont.sidebarRow)
                .foregroundStyle(.ofInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, SidebarStyle.rowPadding)
        .frame(height: Metrics.sidebarRowHeight)
        .contentShape(Rectangle())
        .modifier(SidebarRowBackground(active: active, hovered: hovered))
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .help(topic.lastError.map { "Last search failed: \($0)" } ?? topic.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread > 0 ? "\(topic.title), \(unread) unread" : topic.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
    }

    /// The unread count (or a spinner while it searches), which the "…" menu takes the place of on hover. The menu
    /// stays in the row, only hidden, so it isn't torn down when the pointer moves onto its popup.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Group {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else if unread > 0 {
                    Text(unread.formatted())
                        .font(OFFont.ui(12))
                        .monospacedDigit()
                        .foregroundStyle(.ofMuted)
                }
            }
            .opacity(hovered ? 0 : 1)
            Menu {
                menu()
            } label: {
                SidebarMiniButtonLabel(icon: .more, size: 22, iconSize: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovered ? 1 : 0)
            .accessibilityLabel("Options for \(topic.title)")
        }
    }
}
