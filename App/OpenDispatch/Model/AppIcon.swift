import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Settings → Appearance → App Icon: a design in a colorway. The icons are drawn by design/app-icons.mjs
/// and rendered by scripts/render-icons.sh: AppIcon is the default (O + D in Glacier), every other pair an
/// iOS alternate icon `AppIcon-<design>-<colorway>`, and every pair a 512 px picture `icon-<design>-<colorway>`
/// for Settings and the Mac's Dock. Raw values are those file names, so keep them in step with the script.
enum AppIconDesign: String, CaseIterable, Identifiable, Sendable {
    case oD = "o-d", swept, twoLines = "two-lines", split, inkCut = "ink-cut", trace, misprint, traceWave = "trace-wave"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oD: "O + D"
        case .swept: "Swept"
        case .twoLines: "Two Lines"
        case .split: "Split"
        case .inkCut: "Ink Cut"
        case .trace: "Trace"
        case .misprint: "Misprint"
        case .traceWave: "Trace + Wave"
        }
    }
}

enum AppIconColorway: String, CaseIterable, Identifiable, Sendable {
    case glacier, paper, night, newsprint, harbor, cobalt, sage, terracotta, graphite
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct AppIconChoice: Hashable, Sendable {
    var design: AppIconDesign
    var colorway: AppIconColorway

    static let standard = AppIconChoice(design: .oD, colorway: .glacier)
    static let all = AppIconDesign.allCases.flatMap { d in AppIconColorway.allCases.map { AppIconChoice(design: d, colorway: $0) } }

    var id: String { "\(design.rawValue)-\(colorway.rawValue)" }
    /// The icon as a square, full-bleed picture (no rounded corners).
    var image: Image { Image("icon-\(id)") }
    /// The iOS alternate icon's name; the default is the primary icon, nil.
    var alternateIconName: String? { self == .standard ? nil : "AppIcon-\(id)" }

    init(design: AppIconDesign, colorway: AppIconColorway) {
        self.design = design
        self.colorway = colorway
    }

    init?(id: String) {
        guard let found = Self.all.first(where: { $0.id == id }) else { return nil }
        self = found
    }
}

/// The chosen app icon, per device. iOS swaps the home screen icon (the system confirms with an alert of its
/// own); the Mac shows it in the Dock while the app runs, since changing the app bundle's icon would break its
/// signature, so Finder and Launchpad keep the default.
@MainActor
@Observable
final class AppIconStore {
    private(set) var choice: AppIconChoice

    /// The Mac's choice. UserDefaults keys keep the app's original name, like the others.
    private static let key = "openfeed.app-icon"

    init() {
        #if os(iOS)
        // The system remembers the alternate icon; trust it over the saved choice.
        let name = UIApplication.shared.alternateIconName
        choice = name.flatMap { AppIconChoice(id: String($0.dropFirst("AppIcon-".count))) } ?? .standard
        #else
        choice = UserDefaults.standard.string(forKey: Self.key).flatMap(AppIconChoice.init(id:)) ?? .standard
        #endif
    }

    func select(_ new: AppIconChoice) {
        guard new != choice else { return }
        #if os(iOS)
        let old = choice
        choice = new
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(new.alternateIconName)
            } catch {
                // Not changed (the system refuses while the app isn't frontmost): show what the home screen has.
                if choice == new { choice = old }
            }
        }
        #else
        choice = new
        UserDefaults.standard.set(new.id, forKey: Self.key)
        showInDock()
        #endif
    }

    /// The Mac: the chosen icon in the Dock, or the bundle's own for the default. Called at launch and on a change.
    func showInDock() {
        #if os(macOS)
        NSApp.applicationIconImage = choice == .standard ? nil : Self.dockImage(choice)
        #endif
    }

    #if os(macOS)
    /// The picture on Apple's Mac icon template: a rounded square 824/1024 of the canvas, centered.
    private static func dockImage(_ choice: AppIconChoice) -> NSImage? {
        guard let art = NSImage(named: "icon-\(choice.id)") else { return nil }
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = rect.insetBy(dx: rect.width * 100 / 1024, dy: rect.height * 100 / 1024)
            let radius = tile.width * 185 / 824
            NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
            art.draw(in: tile)
            return true
        }
    }
    #endif
}
