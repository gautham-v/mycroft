import OpenDispatchCore
import SwiftUI

/// The confirmation after Copy as Markdown ("Copied as Markdown · 2,340 words", "Copying…", "Couldn't
/// copy: …"): a small rounded rectangle at the bottom center of the window, ~2 s. Overlaid on the
/// root layout; it never takes clicks. With Reduce Motion it fades instead of sliding up.
struct CopyToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    /// Clears the floating tab bar on iPhone.
    private static let bottomInset: CGFloat = 56
    #else
    private static let bottomInset: CGFloat = 24
    #endif

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = model.copyToast {
                    CopyToastView(toast: toast)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Self.bottomInset)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.copyToast)
        }
    }
}

extension View {
    func copyToastOverlay() -> some View { modifier(CopyToastOverlay()) }
}

private struct CopyToastView: View {
    let toast: CopyToast

    var body: some View {
        VStack(spacing: 2) {
            Text(toast.message)
                .font(OFFont.ui(13.5, .medium))
                .foregroundStyle(toast.kind == .failed ? Color.ofDanger : Color.ofInk)
            if let note = toast.note {
                Text(note)
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofMuted)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(Color.ofSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ofBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// "Copy Last 24 Hours" and "Copy Last 7 Days" for a view, folder or source, to sit in its context menu
/// (after a divider).
struct CopyDigestButtons: View {
    let scope: DigestScope
    /// Menus that show an icon on every item (the iPhone Sources tab).
    var icons = false
    @Environment(AppModel.self) private var model

    var body: some View {
        button("Copy Last 24 Hours", days: 1)
        button("Copy Last 7 Days", days: 7)
    }

    @ViewBuilder private func button(_ title: String, days: Int) -> some View {
        Button {
            model.copyDigest(scope, days: days)
        } label: {
            if icons {
                Label(title, systemImage: "doc.on.doc")
            } else {
                Text(title)
            }
        }
    }
}
