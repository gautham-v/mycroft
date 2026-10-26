import OpenDispatchCore
import SwiftUI

/// About pane (native): logo, version, what the app is, and credits.
struct SettingsAboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "About", hint: "A reader for blogs, YouTube channels, podcasts and posts.")
            HStack(spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        FeedMarkIcon(size: 16)
                        Text("OpenDispatch")
                            .font(OFFont.ui(17, .semibold))
                            .tracking(-0.17)
                            .foregroundStyle(.ofInk)
                    }
                    Text(version)
                        .font(OFFont.ui(12.5))
                        .foregroundStyle(.ofMuted)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .top) { SettingsHairline() }

            paragraph("RSS and Atom feeds, YouTube channels, podcasts and plain web pages in one list. No account, no server and no sync: your sources, saved items and cached articles live in a database on this device.")
            paragraph("Feeds refresh when you open the app and every so often while it is open. Items older than \(Retention.days) days are removed unless you saved them.")

            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionLabel(text: "Credits")
                credit("Readability.js", "Article extraction. Mozilla, Apache License 2.0.", "https://github.com/mozilla/readability")
                credit("GRDB.swift", "SQLite toolkit. MIT License.", "https://github.com/groue/GRDB.swift")
                credit("SwiftSoup", "HTML parsing. MIT License.", "https://github.com/scinfu/SwiftSoup")
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { SettingsHairline() }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofBody)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }

    private func credit(_ name: String, _ detail: String, _ link: String) -> some View {
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
    }
}
