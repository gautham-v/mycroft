import SwiftUI

/// How list rows are drawn (Settings → Appearance → Lists), set on the root view from AppSettings so
/// every list, the sidebar and the reader header read the same values.
struct ListLayout: Equatable, Sendable {
    var density: ListDensitySetting = .comfortable
    var thumbnails: ListThumbnailSetting = .small
    var unreadMarker: UnreadMarkerSetting = .dim
    var sourceIcons: SourceIconSetting = .color

    var isCompact: Bool { density == .compact }

    /// Row padding, top and bottom.
    func rowPaddingV(phone: Bool) -> CGFloat {
        switch (phone, isCompact) {
        case (true, false): Metrics.phoneRowPaddingV
        case (true, true): 11
        case (false, false): Metrics.rowPaddingV
        case (false, true): 6
        }
    }

    /// Thumbnail scale against the original sizes (64×42 on the Mac and iPad, 80pt square on iPhone).
    var thumbnailScale: CGFloat { thumbnails == .large ? 1.375 : 1 }
}

private struct ListLayoutKey: EnvironmentKey {
    static let defaultValue = ListLayout()
}

extension EnvironmentValues {
    var listLayout: ListLayout {
        get { self[ListLayoutKey.self] }
        set { self[ListLayoutKey.self] = newValue }
    }
}

/// The dot that leads an unread row's meta line (Unread marker: Dot on unread), in the accent color.
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.ofAccent)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
