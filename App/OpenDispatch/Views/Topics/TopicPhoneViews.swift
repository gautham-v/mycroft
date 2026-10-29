#if os(iOS)
import OpenDispatchCore
import SwiftUI

/// The line under a topic's title on the iPhone: what it is and when it last searched (or that the last
/// search failed), with a spinner while it searches. A list row, so it scrolls away with the title.
struct PhoneTopicStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let topic = model.activeTopic {
            HStack(spacing: 6) {
                Text(TopicListBar.statusText(topic))
                    .font(OFFont.ui(14))
                    .foregroundStyle(topic.lastError != nil && topic.lastFetchedAt != nil ? Color.ofDanger : Color.ofMuted)
                    .lineLimit(1)
                if model.topicStore.refreshing.contains(topic.id) {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

/// The chips (All, Articles, Discussions, Videos, Episodes) as a pinned section header of a topic's list,
/// on the list's ground so rows scroll under them.
struct PhoneTopicChipsHeader: View {
    var body: some View {
        TopicChips()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ofSurface)
            .textCase(nil)
            .listRowInsets(EdgeInsets())
    }
}

/// A topic's actions among the home list's bottom bubbles: one glass pill with the Notify on New Matches bell
/// and a menu (Edit Topic, Mark All as Read, Remove Topic). The home list has no navigation bar, so these
/// take the place of toolbar items.
struct PhoneTopicBubbles: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsRemoval = false
    @State private var error: String?

    var body: some View {
        if let topic = model.activeTopic {
            HStack(spacing: 0) {
                Button {
                    Task {
                        do { try await model.setSourceNotify(id: topic.id, on: !topic.notifies) } catch { self.error = HTTP.message(error) }
                    }
                } label: {
                    Image(systemName: topic.notifies ? "bell.fill" : "bell")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(topic.notifies ? Color.ofAccent : Color.ofInk)
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notify on New Matches")
                .accessibilityValue(topic.notifies ? "On" : "Off")
                Menu {
                    Button {
                        model.beginEditTopic(topic)
                    } label: {
                        Label("Edit Topic\u{2026}", systemImage: "pencil")
                    }
                    Button {
                        model.markAllRead(topic: topic)
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmsRemoval = true
                    } label: {
                        Label("Remove Topic\u{2026}", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.ofInk)
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .tint(.ofInk)
                .accessibilityLabel("Topic actions")
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .alert("Remove \(topic.title)?", isPresented: $confirmsRemoval) {
                Button("Remove Topic", role: .destructive) {
                    Task {
                        do { try await model.deleteTopic(id: topic.id) } catch { self.error = HTTP.message(error) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removing a topic also removes its items.")
            }
            .alert("Couldn\u{2019}t change notifications", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }
}
#endif
