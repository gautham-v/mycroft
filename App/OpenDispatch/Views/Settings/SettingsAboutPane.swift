import OpenDispatchCore
import SwiftUI

/// About pane (native): logo, version, what the app is, and credits. On a phone the logo and version
/// are the Settings screen's header, so the pane starts at the description, and the text and credits
/// sit in cards. Figtree is credited on iOS only, the one platform that sets its UI in it.
struct SettingsAboutPane: View {
    @Environment(\.settingsCompact) private var compact

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    private static let about = [
        "RSS and Atom feeds, YouTube channels, podcasts and plain web pages in one list. No account, no server and no sync: your sources, saved items and cached articles live in a database on this device.",
        "Feeds refresh when you open the app and every so often while it is open. Items older than \(Retention.days) days are removed unless you saved them.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "About", hint: "A reader for blogs, YouTube channels, podcasts and posts.")
            if compact {
                SettingsCard {
                    ForEach(Self.about, id: \.self) { text in
                        paragraph(text).padding(.vertical, 14)
                    }
                }
                SettingsSectionLabel(text: "Credits")
                SettingsCard {
                    credits
                }
            } else {
                HStack(spacing: 14) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenDispatch")
                            .font(OFFont.ui(17, .semibold))
                            .tracking(-0.17)
                            .foregroundStyle(.ofInk)
                        Text(version)
                            .font(OFFont.ui(12.5))
                            .foregroundStyle(.ofMuted)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 18)

                SettingsCard {
                    ForEach(Self.about, id: \.self) { text in
                        paragraph(text).padding(.vertical, 12)
                    }
                }

                SettingsSectionLabel(text: "Credits")
                SettingsCard {
                    credits
                }
            }
        }
    }

    @ViewBuilder private var credits: some View {
        credit("Readability.js", "Article extraction. Mozilla, Apache License 2.0.", "https://github.com/mozilla/readability")
        credit("GRDB.swift", "SQLite toolkit. MIT License.", "https://github.com/groue/GRDB.swift")
        credit("SwiftSoup", "HTML parsing. MIT License.", "https://github.com/scinfu/SwiftSoup")
        #if os(iOS)
        credit("Figtree", "Typeface. Erik Kennedy, SIL Open Font License 1.1.", "https://github.com/erikdkennedy/figtree")
        #endif
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(OFFont.ui(compact ? 15 : 13))
            .foregroundStyle(.ofBody)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func credit(_ name: String, _ detail: String, _ link: String) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 2) {
                if let url = URL(string: link) {
                    Link(name, destination: url)
                        .font(OFFont.ui(17))
                        .foregroundStyle(.ofInk)
                }
                Text(detail)
                    .font(OFFont.ui(13.5))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let url = URL(string: link) {
                    Link(name, destination: url)
                        .font(OFFont.ui(13, .medium))
                        .foregroundStyle(.ofAccent)
                }
                Text(detail)
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
    }
}
