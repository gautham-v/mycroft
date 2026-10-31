import OpenDispatchCore
import SwiftUI

/// "Mute in Feeds" in a source's menu, or a disabled "Muted with <Folder>" while its folder is muted.
struct MuteSourceMenuItem: View {
    let source: Source
    /// Menus that show an icon on every item (iPhone).
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if let folder = model.mutingFolder(of: source) {
            MuteMenuToggle(title: "Muted with \(folder.title)", isOn: true, icons: icons) {}
                .disabled(true)
        } else {
            MuteMenuToggle(title: source.isMuted && icons ? "Unmute in Feeds" : "Mute in Feeds", isOn: source.isMuted, icons: icons) {
                Task { await model.setSourceMuted(id: source.id, muted: !source.isMuted) }
            }
        }
    }
}

/// "Mute Folder in Feeds" in a folder's menu.
struct MuteFolderMenuItem: View {
    let folder: Folder
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        MuteMenuToggle(title: folder.isMuted && icons ? "Unmute Folder in Feeds" : "Mute Folder in Feeds", isOn: folder.isMuted, icons: icons) {
            Task { await model.setFolderMuted(id: folder.id, muted: !folder.isMuted) }
        }
    }
}

/// "Mute Adam Schefter" in a feed row's menu, for a source that can be muted.
struct MuteRowMenuItem: View {
    let item: FeedItem
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        // The row's copy of the source dates from when the list loaded.
        if !item.source.isTopic, !item.source.isOpenedLinks {
            let source = model.sources.first { $0.id == item.source.id } ?? item.source
            if let folder = model.mutingFolder(of: source) {
                MuteMenuButton(title: "Muted with \(folder.title)", icons: icons) {}
                    .disabled(true)
            } else {
                MuteMenuButton(title: "\(source.isMuted ? "Unmute" : "Mute") \(source.shortTitle)", icons: icons, isOn: source.isMuted) {
                    Task { await model.setSourceMuted(id: source.id, muted: !source.isMuted) }
                }
            }
        }
    }
}

/// For You's part of a feed row's menu: why the row is where it is, Show More and Show Less. Only while the list is in For
/// You order, which is the only order they change.
struct ForYouRowMenuItems: View {
    let item: FeedItem
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        // A topic's list can hold rows of the user's own sources, but it stays Balanced.
        if model.listOrder == .forYou, !model.isTopicSelected, !item.source.isTopic, !item.source.isOpenedLinks {
            let source = model.sources.first { $0.id == item.source.id } ?? item.source
            let preference = model.settings.sourcePreferences[source.feedUrl] ?? 0
            Section(model.whyHere(source)) {
                toggle("Show More from \(source.shortTitle)", symbol: "arrow.up.circle", isOn: preference == 1) {
                    model.setSourcePreference(source, to: preference == 1 ? 0 : 1)
                }
                toggle("Show Less from \(source.shortTitle)", symbol: "arrow.down.circle", isOn: preference == -1) {
                    model.setSourcePreference(source, to: preference == -1 ? 0 : -1)
                }
            }
        }
    }

    private func toggle(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            if icons {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
    }
}

/// "Remove Adam Schefter" in a feed row's menu, under Mute: gone at once with Undo in the toast, or asked first when its saved
/// items would go with it.
struct RemoveRowMenuItem: View {
    let item: FeedItem
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if !item.source.isTopic, !item.source.isOpenedLinks {
            let source = model.sources.first { $0.id == item.source.id } ?? item.source
            Button(role: .destructive) {
                Task { await model.removeSourceFromRow(source) }
            } label: {
                if icons {
                    Label("Remove \(source.shortTitle)", systemImage: "trash")
                } else {
                    Text("Remove \(source.shortTitle)")
                }
            }
        }
    }
}

/// "Block note.com" in the menu of a topic's row: what the row came from leaves this topic, with Undo in the toast.
struct BlockRowMenuItem: View {
    let item: FeedItem
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.blockTarget(for: item) {
            Button {
                Task { await model.block(target.key, inTopic: target.topic) }
            } label: {
                if icons {
                    Label("Block \(target.key)", systemImage: "nosign")
                } else {
                    Text("Block \(target.key)")
                }
            }
        }
    }
}

/// A checkable item on the Mac and iPad sidebar's plain menus; with icons, a button whose words say what it does.
private struct MuteMenuToggle: View {
    let title: String
    let isOn: Bool
    var icons = false
    let action: () -> Void

    var body: some View {
        if icons {
            MuteMenuButton(title: title, icons: true, isOn: isOn, action: action)
        } else {
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
        }
    }
}

private struct MuteMenuButton: View {
    let title: String
    var icons = false
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if icons {
                Label(title, systemImage: isOn ? "speaker.wave.2" : "speaker.slash")
            } else {
                Text(title)
            }
        }
    }
}

/// Over a muted source's or folder's list: that it isn't in the feeds, and Unmute. In the header's bar on the Mac and
/// iPad (`desktopHeight`, which the list's top inset makes room for), under the title on iPhone.
struct MutedListBanner: View {
    static let desktopHeight: CGFloat = 30
    var isPhone = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note = model.mutedListNote {
            let line = HStack(spacing: 8) {
                Text(note.text)
                    .font(OFFont.ui(isPhone ? 14 : 12.5))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(isPhone ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = note.actionTitle, let target = note.unmute {
                    Button(title) { Task { await model.unmute(target) } }
                        .buttonStyle(.plain)
                        .font(OFFont.ui(isPhone ? 14 : 12.5, .medium))
                        .foregroundStyle(.ofAccent)
                        .fixedSize()
                }
            }
            if isPhone {
                line
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.ofNavHover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                line
                    .padding(.horizontal, 18)
                    .frame(height: Self.desktopHeight)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
            }
        }
    }
}

/// The list's top inset on the Mac and iPad, with room for the banner. Its own modifier so the list's body doesn't read
/// what the banner depends on.
struct MutedListContentInset: ViewModifier {
    let base: CGFloat
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.topContentInset(base + (model.mutedListNote == nil ? 0 : MutedListBanner.desktopHeight))
    }
}

/// Keeps the new-rows pill under the banner on the Mac and iPad.
struct MutedListPillInset: ViewModifier {
    let isPhone: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.padding(.top, !isPhone && model.mutedListNote != nil ? MutedListBanner.desktopHeight : 0)
    }
}

/// The confirmation after muting, removing a source from a row or blocking in a topic: what happened and Undo, at the bottom of
/// the window for 6 s. On iPhone it sits above the list's bubbles. With Reduce Motion it fades instead of sliding up. It also holds
/// the question a row's Remove asks when saved items would go with the source, since the row's menu is gone by then.
struct UndoToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var bottomInset: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 84 : 24
        #else
        24
        #endif
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = model.undoToast {
                    UndoToastView(toast: toast)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.undoToast)
        }
        .confirmationDialog(
            model.sourceRemovalToConfirm.map { "Remove \($0.source.shortTitle)?" } ?? "Remove source?",
            isPresented: Binding(get: { model.sourceRemovalToConfirm != nil }, set: { if !$0 { model.sourceRemovalToConfirm = nil } }),
            titleVisibility: .visible,
            presenting: model.sourceRemovalToConfirm
        ) { request in
            Button("Remove", role: .destructive) { Task { await model.holdSourceRemoval(request.source) } }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func undoToastOverlay() -> some View { modifier(UndoToastOverlay()) }
}

private struct UndoToastView: View {
    let toast: UndoToast
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(OFFont.ui(13.5, .medium))
                .foregroundStyle(.ofInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Undo") { Task { await model.undoLastAction() } }
                .buttonStyle(.plain)
                .font(OFFont.ui(13.5, .semibold))
                .foregroundStyle(.ofAccent)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(Color.ofSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ofBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}
