#if os(iOS)
import SwiftUI

// The grouped-card look of the iPhone's Settings and Sources screens: muted label, a white card with
// 26pt corners on the warm ground, 17pt rows, hairlines inset 20pt.

/// A white card whose children are rows, with a hairline between them inset 20pt like the rows.
struct GroupedCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews.indices, id: \.self) { i in
                    if i > 0 { Rectangle().fill(Color.ofHairline).frame(height: 1) }
                    subviews[i]
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ofCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// The muted 15pt label above a card.
struct GroupedLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OFFont.ui(15, .medium))
            .foregroundStyle(.ofMuted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }
}

/// A card row's content: an optional leading view, the title (with a muted subline), then a trailing
/// detail and a faint chevron. Put it in a Button, or use it bare.
struct GroupedRow<Leading: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var chevron = true
    var weight: Font.Weight = .regular
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 13) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OFFont.ui(17, weight))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(OFFont.ui(13.5))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(OFFont.ui(16))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
            if chevron {
                OFIcon.chevron.image
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ofFaint)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension GroupedRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, detail: String? = nil, chevron: Bool = true, weight: Font.Weight = .regular) {
        self.init(title: title, subtitle: subtitle, detail: detail, chevron: chevron, weight: weight) { EmptyView() }
    }
}

/// The 34pt rounded square behind a row's leading icon.
struct GroupedIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.ofInk)
            .frame(width: 34, height: 34)
            .background(Color.ofCardInset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Row press feedback: the row dims while pressed.
struct GroupedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}
#endif
