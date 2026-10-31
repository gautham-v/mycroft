import OpenDispatchCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Toolbar icon button (ActionButton in reader.tsx): 30pt on desktop, 44pt touch target on phones,
/// ink icon (like Claude's bar), 7pt rounded hover background.
struct ReaderIconButtonStyle: ButtonStyle {
    var size: CGFloat
    var glyph: CGFloat = 17

    func makeBody(configuration: Configuration) -> some View {
        ReaderIconButtonBody(configuration: configuration, size: size, glyph: glyph)
    }
}

private struct ReaderIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let glyph: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: glyph, weight: .regular))
            .foregroundStyle(Color.ofInk)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Color.ofHover : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.6)
            .onHover { hovering = $0 }
    }
}

/// Wrapping row for bylines and meta (flex-wrap with x/y gaps).
struct ReaderFlowLayout: Layout {
    var spacingX: CGFloat = 14
    var spacingY: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacingY * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - fitted.height) / 2),
                                      proposal: ProposedViewSize(fitted))
                x += fitted.width + spacingX
            }
            y += row.height + spacingY
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            let needed = current.indices.isEmpty ? w : current.width + spacingX + w
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? w : current.width + spacingX + w
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The reading column (Settings → Appearance → Reader width, 640pt by default, or the whole pane with
/// Fill window) with 20pt (phone) / 32pt (wider) side padding outside it, or `padding` when given.
struct ReaderColumn: ViewModifier {
    var wide: Bool
    var padding: CGFloat?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        // Aligned to the top: the comments' LazyVStack changes height as rows appear, and centered that moves them up over the post.
        content
            .frame(maxWidth: model.settings.readerColumnWidth ?? .infinity, alignment: .topLeading)
            .padding(.horizontal, padding ?? (wide ? Metrics.readerPaddingWide : Metrics.readerPaddingPhone))
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func readerColumn(wide: Bool, padding: CGFloat? = nil) -> some View { modifier(ReaderColumn(wide: wide, padding: padding)) }

    /// Cuts text to `limit` lines (nil: all of it) and tells `truncated` whether that left any out.
    func readerClamped(_ limit: Int?, truncated: Binding<Bool>) -> some View {
        modifier(ReaderClamp(limit: limit, truncated: truncated))
    }
}

/// `readerClamped`: the text cut to its lines over a hidden copy at full length; the two heights differ when it was cut.
private struct ReaderClamp: ViewModifier {
    let limit: Int?
    @Binding var truncated: Bool
    @State private var full: CGFloat = 0
    @State private var shown: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .lineLimit(limit)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .topLeading) {
                content
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0; update() }
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0; update() }
    }

    private func update() {
        let cut = limit != nil && full > shown + 1
        if cut != truncated { truncated = cut }
    }
}

/// "Show more", "Read more", "2 more replies": in the muted meta color with a chevron that turns up once open, in ink
/// under the pointer, so opening something in place doesn't look like a link out.
struct ReaderDisclosureButton: View {
    let title: String
    var open = false
    var size: CGFloat = 13.5
    /// Drawn in place of the muted color (a row that failed to load), without the chevron.
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if tint == nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .font(OFFont.ui(size, .medium))
            .foregroundStyle(tint ?? (hovering ? Color.ofInk : Color.ofMuted))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Pure helpers ported from reader.tsx.
enum ReaderText {
    /// URL_RE in reader.tsx (Linkified).
    private static let urlPattern = #"(https?://[^\s<>"')]+[^\s<>"').,;:!?])"#
    private static let urlRegex = try? NSRegularExpression(pattern: urlPattern)
    private static let imgRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    /// Plain text with http(s) URLs turned into links (Text tints them with the accent).
    static func linkified(_ text: String) -> AttributedString {
        let ns = text as NSString
        let attributed = NSMutableAttributedString(string: text)
        if let regex = urlRegex {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = URL(string: ns.substring(with: match.range)) else { continue }
                attributed.addAttribute(.link, value: url, range: match.range)
            }
        }
        return AttributedString(attributed)
    }

    /// stripImage: removes <img> tags whose src is `src` (raw or HTML-escaped), so podcast art isn't shown twice.
    static func stripImage(_ html: String, src: String) -> String {
        guard let regex = imgRegex else { return html }
        let variants = [src, src.replacingOccurrences(of: "&", with: "&amp;")]
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard variants.contains(where: { tag.contains("\"\($0)\"") || tag.contains("'\($0)'") }) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// A page's hero video or the hero image already leads the extracted HTML, or the hero file is in it further down
    /// (the same file in another size, crop or CDN path). The rule lives in Core (`LeadImage`), where the extractor
    /// applies the same one.
    static func contentHasHero(_ html: String, hero: String) -> Bool {
        LeadImage.contentHasHero(html, hero: hero)
    }
}

@MainActor
enum ReaderPasteboard {
    static func copy(_ url: URL) {
        #if canImport(UIKit)
        UIPasteboard.general.url = url
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }

    /// Plain text (Copy as Markdown).
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
