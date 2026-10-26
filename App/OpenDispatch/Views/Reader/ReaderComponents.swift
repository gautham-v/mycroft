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

/// The 640pt reading column with 20pt (phone) / 32pt (wider) side padding outside it.
struct ReaderColumn: ViewModifier {
    var wide: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Metrics.readerMaxWidth, alignment: .leading)
            .padding(.horizontal, wide ? Metrics.readerPaddingWide : Metrics.readerPaddingPhone)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func readerColumn(wide: Bool) -> some View { modifier(ReaderColumn(wide: wide)) }
}

/// Pure helpers ported from reader.tsx.
enum ReaderText {
    /// URL_RE in reader.tsx (Linkified).
    private static let urlPattern = #"(https?://[^\s<>"')]+[^\s<>"').,;:!?])"#
    private static let urlRegex = try? NSRegularExpression(pattern: urlPattern)
    private static let imgRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    private static let leadingEmbedRegex = try? NSRegularExpression(pattern: #"^\s*<(?:iframe|video)\b"#, options: [.caseInsensitive])

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

    /// A page's hero video or the hero image already leads the extracted HTML.
    static func contentHasHero(_ html: String, hero: String) -> Bool {
        if html.contains(hero) || html.contains(hero.replacingOccurrences(of: "&", with: "&amp;")) { return true }
        // Same image in another size or crop (WordPress ?w=1200 vs ?fit=…, -1024x576, -e1790…, -scaled):
        // compare the content's first image by normalized file name.
        if let first = firstImageSrc(html), let a = imageStem(first), let b = imageStem(hero), a == b { return true }
        guard let regex = leadingEmbedRegex else { return false }
        return regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) != nil
    }

    private static let firstImgSrcRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
    private static let stemSuffixRegex = try? NSRegularExpression(pattern: #"(?:-e\d{6,}|-\d{2,5}x\d{2,5}|-scaled|-\d)$"#)

    /// src of the first <img>, only when it comes before any text (the content leads with it).
    private static func firstImageSrc(_ html: String) -> String? {
        let ns = html as NSString
        guard let m = firstImgSrcRegex?.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let before = ns.substring(to: m.range.location)
        guard TextFormat.stripHTML(before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
    }

    /// host + directory + file name without extension and without size/crop/duplicate suffixes.
    private static func imageStem(_ url: String) -> String? {
        guard let comps = URLComponents(string: url), let host = comps.host else { return nil }
        let path = comps.path
        guard let slash = path.lastIndex(of: "/") else { return nil }
        var name = String(path[path.index(after: slash)...]).lowercased()
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        while let r = stemSuffixRegex, let m = r.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) {
            name = (name as NSString).substring(to: m.range.location)
        }
        guard name.count >= 4 else { return nil }
        return host.lowercased() + path[..<slash].lowercased() + "/" + name
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
}
