import OpenDispatchCore
import SwiftUI

/// The bar under a topic's list header on the Mac and iPad: what the topic is and when it last searched,
/// the Notify on New Matches bell, Edit, and the chips that filter the list by kind. Shows nothing for
/// any other list. The header above it holds the keyword (as the list's title).
struct TopicListBar: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    /// The bar's height, so the list can leave room for it.
    static let height: CGFloat = 78

    var body: some View {
        if let topic = model.activeTopic {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 2) {
                    status(topic)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    bell(topic)
                    Button { model.beginEditTopic(topic) } label: {
                        Text("Edit")
                            .font(OFFont.ui(13, .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedHoverIconButtonStyle())
                    .help("Edit Topic")
                    .accessibilityLabel("Edit Topic")
                }
                TopicChips()
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 6)
            .frame(height: Self.height, alignment: .top)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
            .frostedBar()
            .alert("Couldn\u{2019}t change notifications", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    /// "Topic · Updated 3h ago", or that it is searching, or that the last search failed.
    private func status(_ topic: Source) -> some View {
        HStack(spacing: 6) {
            Text(TopicListBar.statusText(topic))
                .font(OFFont.ui(13))
                .foregroundStyle(topic.lastError != nil && topic.lastFetchedAt != nil ? Color.ofDanger : Color.ofMuted)
                .lineLimit(1)
            if model.topicStore.refreshing.contains(topic.id) {
                ProgressView().controlSize(.mini)
            }
        }
        .help(topic.lastError ?? "")
    }

    static func statusText(_ topic: Source) -> String {
        if topic.lastError != nil, topic.lastFetchedAt != nil { return "Topic \u{00B7} Couldn\u{2019}t update" }
        guard let at = topic.lastFetchedAt else { return "Topic \u{00B7} Not searched yet" }
        let age = RelativeTime.format(at)
        return "Topic \u{00B7} Updated " + (age == "now" ? "just now" : "\(age) ago")
    }

    private func bell(_ topic: Source) -> some View {
        Button {
            Task {
                do { try await model.setSourceNotify(id: topic.id, on: !topic.notifies) } catch { self.error = HTTP.message(error) }
            }
        } label: {
            Image(systemName: topic.notifies ? "bell.fill" : "bell")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedHoverIconButtonStyle(baseColor: topic.notifies ? .ofAccent : .ofMuted))
        .help(topic.notifies ? "Stop notifying on new matches" : "Notify on new matches")
        .accessibilityLabel("Notify on New Matches")
        .accessibilityValue(topic.notifies ? "On" : "Off")
    }
}

/// All / Articles / Discussions / Videos / Episodes: which kind of item the open topic lists.
struct TopicChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(TopicContentFilter.allCases) { filter in
                    chip(filter)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ filter: TopicContentFilter) -> some View {
        let selected = model.topicFilter == filter
        return Button { model.setTopicFilter(filter) } label: {
            Text(filter.title)
                .font(OFFont.ui(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.ofInk : Color.ofMuted)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(selected ? Color.ofSelection : Color.ofCode, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
