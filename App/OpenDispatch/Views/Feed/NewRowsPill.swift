import OpenDispatchCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Rows a refresh added above the ones on screen. The list keeps what's on screen in place when rows land above it
/// (SwiftUI does on the Mac, `ListAnchor` on iOS) and says so with the pill (`NewRowsPill`) instead; the count goes
/// down as the new rows scroll into view.
@MainActor @Observable final class NewRows {
    /// The new rows still above the screen, in list order.
    private(set) var above: [FeedItem] = []
    /// The first item row on screen, as the list last reported it; read when a refresh lands.
    @ObservationIgnored private var topID: Int64?
    /// Until then the list's reports are its layout settling around the new rows (the Mac lays them out at the top
    /// for a moment before putting the old rows back), so they are ignored.
    @ObservationIgnored private var settlingUntil = Date.distantPast
    /// Pull to refresh: the new rows show at the top, so there is nothing to point at.
    @ObservationIgnored private var revealingUntil = Date.distantPast

    /// A reload added `ids`: the ones above the row that was first on screen go in the pill.
    func arrived(_ ids: Set<Int64>, in items: [FeedItem]) {
        guard !ids.isEmpty, Date() >= revealingUntil else { return }
        let end = topID.flatMap { id in items.firstIndex { $0.id == id } } ?? items.count
        let pending = Set(above.map(\.id)).union(ids)
        above = items.prefix(end).filter { pending.contains($0.id) }
        settlingUntil = Date().addingTimeInterval(0.5)
    }

    /// The first item row on screen changed: new rows from there down are on screen or below it.
    func scrolled(toTop id: Int64?, in items: [FeedItem]) {
        guard Date() >= settlingUntil else { return }
        topID = id
        guard !above.isEmpty, let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let stillAbove = Set(items.prefix(index).map(\.id))
        let next = above.filter { stillAbove.contains($0.id) }
        if next.count != above.count { above = next }
    }

    /// The Mac's visible rows: the topmost of them in list order.
    func scrolled(toFirstOf visible: [Int64], in items: [FeedItem]) {
        guard Date() >= settlingUntil else { return }
        let ids = Set(visible)
        scrolled(toTop: items.first { ids.contains($0.id) }?.id, in: items)
    }

    func reveal(until date: Date) { revealingUntil = date }

    func clear() {
        if !above.isEmpty { above = [] }
    }
}

/// "↑ 4 new" over the top of the list, with the new rows' source icons; clicking it scrolls to the top.
struct NewRowsPill: View {
    let rows: NewRows
    var isPhone = false
    let action: () -> Void

    var body: some View {
        let above = rows.above
        ZStack {
            if !above.isEmpty {
                Button(action: action) { label(above) }
                    .buttonStyle(.plain)
                    .modifier(PillBackground(isPhone: isPhone))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel(above.count == 1 ? "1 new item" : "\(above.count) new items")
                    .accessibilityHint("Scrolls to the top of the list")
                    .help("Scroll to the new items")
            }
        }
        .animation(.smooth(duration: 0.25), value: above.isEmpty)
    }

    private func label(_ above: [FeedItem]) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: -5) {
                ForEach(Self.badgeItems(above), id: \.id) { item in
                    SourceBadge(host: item.source.host, title: item.originName, size: isPhone ? 20 : 18)
                        .padding(1.5)
                        .background(Color.ofSurface, in: RoundedRectangle(cornerRadius: isPhone ? 7 : 6.5, style: .continuous))
                }
            }
            Text("\(above.count) new")
                .monospacedDigit()
            Image(systemName: "arrow.up")
                .font(.system(size: isPhone ? 13 : 11, weight: .bold))
                .foregroundStyle(.ofAccent)
        }
        .font(OFFont.ui(isPhone ? 15 : 13, .semibold))
        .foregroundStyle(.ofInk)
        .padding(.leading, 5)
        .padding(.trailing, isPhone ? 14 : 12)
        .frame(height: isPhone ? 38 : 30)
        .contentShape(Capsule())
    }

    /// Up to three icons, one per source, newest first.
    private static func badgeItems(_ items: [FeedItem]) -> [FeedItem] {
        var seen: Set<String> = []
        var picked: [FeedItem] = []
        for item in items where seen.insert(item.source.host + "|" + item.originName).inserted {
            picked.append(item)
            if picked.count == 3 { break }
        }
        return picked
    }
}

/// Liquid Glass on iOS, like the iPhone's bubbles; a material capsule on the Mac (macOS 15 has no glass).
private struct PillBackground: ViewModifier {
    let isPhone: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.glassEffect(.regular.interactive(), in: .capsule)
        #else
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.ofHairline))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        #endif
    }
}

#if os(iOS)
/// Keeps the rows on screen where they are when the list's rows change above them (a refresh adding items, Hide Read
/// Items leaving out ones read since). List is a UICollectionView, which keeps its content offset, so rows added above
/// pushed everything on screen down. This records the first item row on screen and its place as the list scrolls,
/// and when a change lands moves the offset so that row stays where it was. Pull to refresh skips it (`reveal`).
@MainActor final class ListAnchor {
    /// Rows the list has above its items (the iPhone's title row).
    var leadingRows = 0
    /// Rows land where they fall instead: a list filling for the first time (the iPhone's Start here board mustn't scroll away).
    var isPaused = false
    /// Told the first item row on screen when it changes.
    var onTopRow: (Int64?) -> Void = { _ in }
    private weak var collectionView: UICollectionView?
    private var observations: [NSKeyValueObservation] = []
    /// The item ids the collection view shows, and the ones the list was last built with.
    private var shown: [Int64] = []
    private var expected: [Int64] = []
    /// The first item row on screen and its top, from the top of the scroll view's bounds.
    private var anchor: (id: Int64, y: CGFloat)?
    private var topRow: Int64?
    /// After a change, the next layout passes size the new rows: the anchor is put back after each of them rather
    /// than recorded again, until then or until a finger moves the list.
    private var holdUntil = Date.distantPast
    private var revealUntil = Date.distantPast

    /// The ids the list's rows are being built with. Called from the list's body, so it lands just before the
    /// collection view updates.
    func expect(_ ids: [Int64]) { expected = ids }

    func reveal(until date: Date) { revealUntil = date }

    func attach(_ cv: UICollectionView) {
        guard collectionView !== cv else { return }
        collectionView = cv
        shown = expected
        observations = [
            cv.observe(\.contentOffset) { [weak self] cv, _ in MainActor.assumeIsolated { self?.scrolled(cv) } },
            cv.observe(\.contentSize) { [weak self] cv, _ in MainActor.assumeIsolated { self?.resized(cv) } },
        ]
        record(cv)
    }

    /// The list's items changed (its onChange, after the collection view updated): in case the content size didn't.
    func itemsChanged() {
        guard let cv = collectionView, expected != shown else { return }
        cv.layoutIfNeeded()
        landed(cv)
    }

    private var isHolding: Bool { Date() < holdUntil }

    private func scrolled(_ cv: UICollectionView) {
        if expected != shown { return landed(cv) }
        if cv.isTracking { holdUntil = .distantPast }
        if !isHolding { record(cv) }
    }

    private func resized(_ cv: UICollectionView) {
        if expected != shown { return landed(cv) }
        if isHolding && !cv.isTracking { restore(cv) } else { record(cv) }
    }

    private func landed(_ cv: UICollectionView) {
        shown = expected
        if isPaused || Date() < revealUntil {
            record(cv)
        } else {
            holdUntil = Date().addingTimeInterval(0.6)
            restore(cv)
        }
    }

    private func record(_ cv: UICollectionView) {
        let top = cv.contentOffset.y + cv.adjustedContentInset.top
        let visible = CGRect(x: 0, y: top, width: cv.bounds.width, height: max(1, cv.bounds.height - cv.adjustedContentInset.top))
        let first = cv.collectionViewLayout.layoutAttributesForElements(in: visible)?
            .filter { $0.representedElementCategory == .cell && $0.indexPath.section == 0
                && shown.indices.contains($0.indexPath.item - leadingRows) }
            .min { $0.indexPath.item < $1.indexPath.item }
        anchor = first.map { (shown[$0.indexPath.item - leadingRows], $0.frame.minY - cv.contentOffset.y) }
        if anchor?.id != topRow {
            topRow = anchor?.id
            onTopRow(topRow)
        }
    }

    private func restore(_ cv: UICollectionView) {
        guard let anchor, let index = shown.firstIndex(of: anchor.id), cv.numberOfSections > 0,
              cv.numberOfItems(inSection: 0) > index + leadingRows,
              let frame = cv.layoutAttributesForItem(at: IndexPath(item: index + leadingRows, section: 0))?.frame else {
            // The row that was on top is gone (read and hidden, or another list): nothing to keep in place.
            holdUntil = .distantPast
            return record(cv)
        }
        let minY = -cv.adjustedContentInset.top
        let maxY = max(minY, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
        let y = min(max(frame.minY - anchor.y, minY), maxY)
        if abs(cv.contentOffset.y - y) > 0.5 { cv.contentOffset.y = y }
    }
}

/// Hands the list's UICollectionView to its `ListAnchor`. Attach as the List's background.
struct ListAnchorFinder: UIViewRepresentable {
    let anchor: ListAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            if let cv = Self.collectionView(near: view) { anchor.attach(cv) }
        }
    }

    /// A background sits beside the list, not inside it: look up a few levels, then down.
    private static func collectionView(near probe: UIView) -> UICollectionView? {
        var container = probe.superview
        for _ in 0..<4 {
            guard let c = container else { return nil }
            if let found = first(in: c) { return found }
            container = c.superview
        }
        return nil
    }

    private static func first(in root: UIView) -> UICollectionView? {
        var queue = [root]
        for _ in 0..<8 where !queue.isEmpty {
            if let cv = queue.lazy.compactMap({ $0 as? UICollectionView }).first { return cv }
            queue = queue.flatMap(\.subviews)
        }
        return nil
    }
}
#endif
