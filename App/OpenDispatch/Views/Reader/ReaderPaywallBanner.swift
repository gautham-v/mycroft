import OpenDispatchCore
import SwiftUI

/// Under an article the extractor could only read the teaser of (`ExtractResult.paywalled`): it says the site shows the rest to
/// subscribers and offers to sign in to it (the sign-in sheet, then the article loads again as you), or "Don't Ask Again".
/// Once declined it is a quiet line with a Sign In… link; signed in to the site and still cut short, the sign-in has likely
/// expired. The small line says what lists do with the site's articles without an account (Settings → Integrations).
struct ReaderPaywallBanner: View {
    let item: FeedItem
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var site: String { Paywalls.site(of: item.item.url) }
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// The source's name when it is the article's own site, else the site.
    private var name: String { Paywalls.site(of: item.source.url) == site ? item.source.title : site }

    var body: some View {
        if model.accounts.signedInSites.contains(site) {
            card(headline: "Your \(site) sign-in may have expired.", caption: nil) {
                primary("Sign In Again\u{2026}")
            }
        } else if model.settings.paywalls.isDeclined(url: item.item.url) {
            HStack(spacing: 4) {
                Text("Not signed in to \(site) \u{00B7}")
                    .foregroundStyle(.ofMuted)
                Button("Sign In\u{2026}", action: signIn)
                    .buttonStyle(.plain)
                    .foregroundStyle(.ofAccent)
            }
            .font(OFFont.ui(13.5))
            .accessibilityElement(children: .combine)
        } else {
            card(headline: "\(name) shows the rest to subscribers.", caption: caption) {
                primary("Sign In to \(site)\u{2026}")
                secondary("Don\u{2019}t Ask Again") { model.settings.paywalls.setDeclined(true, url: item.item.url) }
            }
        }
    }

    /// What the lists do with the site's articles while the app isn't signed in to it.
    private var caption: String {
        switch model.settings.paywallTreatment {
        case .mark: "Without an account, \(site) articles get a lock in your lists."
        case .hide: "Without an account, \(site) articles are hidden from your lists."
        case .show: "Without an account, \(site) articles show only what the site gives everyone."
        }
    }

    private func signIn() {
        model.accounts.signingIn = .opening(site, startingAt: URL(string: item.item.url))
    }

    private func card(headline: String, caption: String?, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(OFFont.ui(15, .medium))
                .foregroundStyle(.ofInk)
                .fixedSize(horizontal: false, vertical: true)
            ReaderFlowLayout(spacingX: 10, spacingY: 10) { buttons() }
                .padding(.top, 12)
            if let caption {
                Text(caption)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ofCode, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var buttonHeight: CGFloat { compact ? 44 : 34 }

    private func primary(_ title: String) -> some View {
        Button(action: signIn) {
            Text(title)
                .font(OFFont.ui(14.5, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: buttonHeight)
                .background(Color.ofAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(OFFont.ui(14.5, .medium))
                .foregroundStyle(.ofInk)
                .padding(.horizontal, 16)
                .frame(height: buttonHeight)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ofBorder))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
