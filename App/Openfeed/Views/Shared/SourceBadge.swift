import OpenfeedCore
import SwiftUI

/// Source favicon (Google s2 at 64px) with a colored monogram fallback. Port of badge.tsx.
/// Corner radius is 29% of the size. Used by list rows (16pt), the reader header and the Sources page.
struct SourceBadge: View {
    let host: String
    let title: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let url = URLHost.faviconURL(host: host) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: monogram
                    default: Color.ofCode
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: (size * 0.29).rounded(), style: .continuous))
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let palette = TextFormat.badgePalette
        let color = Color(hexString: palette[TextFormat.badgeColorIndex(host.isEmpty ? title : host)])
        return ZStack {
            color
            Text(TextFormat.monogram(title: title, host: host))
                .font(.system(size: (size * 0.45).rounded(), weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

extension SourceBadge {
    init(source: Source, size: CGFloat = 16) {
        self.init(host: source.host, title: source.title, size: size)
    }
}
