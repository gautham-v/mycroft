import OpenDispatchCore
import SwiftUI

/// A topic's part of its list's title menu (the "Firefox ▾" button on the Mac and iPad, the press-and-hold title on the
/// iPhone): Show (All / News / Discussions / Videos / Episodes, the current one checked, each with its count), then Notify on
/// New Matches (the switch a source's Notify on New Posts is, with the same permission prompt), Edit Topic… and Mark All as
/// Read. A topic's list has nothing else of its own: no bar, no chips, no bell.
///
/// A failed Notify change (notifications off for the app) goes to `error`, which the menu's owner shows with
/// `topicNotifyAlert`: an alert can't be attached to menu content.
struct TopicListMenuItems: View {
    let topic: Source
    @Binding var error: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.topicStore.filterCounts
        Section("Show") {
            ForEach(TopicContentFilter.allCases) { filter in
                Toggle(Self.label(filter, count: counts[filter]), isOn: Binding(
                    get: { model.topicFilter == filter },
                    set: { _ in model.setTopicFilter(filter) }))
            }
        }
        Section {
            Toggle("Notify on New Matches", isOn: Binding(
                get: { topic.notifies },
                set: { on in
                    Task {
                        do { try await model.setSourceNotify(id: topic.id, on: on) } catch { self.error = HTTP.message(error) }
                    }
                }))
            Button("Edit Topic\u{2026}") { model.beginEditTopic(topic) }
            Button("Mark All as Read") { model.markAllRead() }
                .disabled(model.items.isEmpty)
        }
    }

    /// "News (8)": the count in secondary position when it is known.
    static func label(_ filter: TopicContentFilter, count: Int?) -> String {
        count.map { "\(filter.title) (\($0))" } ?? filter.title
    }
}

extension View {
    /// The alert for a failed Notify on New Matches change made from a topic's title menu.
    func topicNotifyAlert(_ error: Binding<String?>) -> some View {
        alert("Couldn\u{2019}t change notifications", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}
