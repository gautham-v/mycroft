import OpenDispatchCore
import SwiftUI

/// Reader toolbar action "Send to" (send-to.tsx): sends the item to Readwise Reader or the webhook.
/// One target configured: sends straight away. Both: a two-item menu. None: opens Settings on the
/// Integrations pane. While sending the icon pulses; on success it turns into an accent check for
/// 1.8 s; an error shows in a small popover for 5 s.
///
/// Given `share`, it is the desktop reader's Share button instead: the share glyph opens one menu with
/// Share…, Copy Link and the send targets, and the same sending / sent / error feedback.
///
///     SendToView(item: item)                       // 30pt desktop button
///     SendToView(item: item, size: Metrics.touchTarget)   // phone
///     SendToView(item: item, share: url)           // desktop reader: Share and Send in one menu
struct SendToView: View {
    let item: FeedItem
    var size: CGFloat = Metrics.desktopIconButton
    var iconSize: CGFloat = 17
    /// In a system toolbar (iPhone reader): primary-colored glyph, no hover background; the bar draws
    /// the Liquid Glass chrome.
    var inSystemToolbar = false
    /// The link to share: Share and Send to become one menu under the share glyph.
    var share: URL? = nil

    /// MENU_LABEL in send-to.tsx.
    static func menuLabel(_ target: SendTarget) -> String {
        target == .readwise ? "Readwise Reader" : "Webhook"
    }

    /// macOS opens the error popover below the button. On iOS 18 `.bottom` makes the popover need room
    /// above this top-of-screen button, so it was silently never presented; `.top` shows it below.
    #if os(macOS)
    private static let errorArrowEdge: Edge = .bottom
    #else
    private static let errorArrowEdge: Edge = .top
    #endif

    private enum Status: Equatable {
        case idle, sending
        case sent(SendTarget)
        case error(String)
    }

    @Environment(AppModel.self) private var model
    @State private var status: Status = .idle
    @State private var timer: Task<Void, Never>?
    @State private var hovering = false

    private var targets: [SendTarget] { model.integrations.configuredTargets }

    private var label: String {
        switch status {
        case .sent(let t): "Sent to \(t.label)"
        case .sending: "Sending…"
        default:
            targets.count == 1 ? "Send to \(targets[0].label)"
                : targets.isEmpty ? "Send to… (set up in Settings)"
                : "Send to…"
        }
    }

    var body: some View {
        Group {
            if let share {
                Menu {
                    shareItems(share)
                } label: {
                    icon
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            } else if targets.count > 1 && status != .sending {
                Menu {
                    ForEach(targets) { t in
                        Button(Self.menuLabel(t)) { Task { await send(to: t) } }
                    }
                } label: {
                    icon
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await tapped() }
                } label: {
                    icon
                }
                .buttonStyle(.plain)
                .disabled(status == .sending)
            }
        }
        .fixedSize()
        .help(share == nil ? label : shareLabel)
        .accessibilityLabel(share == nil ? label : shareLabel)
        .onHover { hovering = $0 }
        .popover(isPresented: errorShown, arrowEdge: Self.errorArrowEdge) {
            if case .error(let message) = status {
                Text(message)
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofDanger)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .presentationCompactAdaptation(.popover)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .onChange(of: item.id) { _, _ in
            timer?.cancel()
            status = .idle
        }
        .onDisappear { timer?.cancel() }
    }

    private var shareLabel: String {
        switch status {
        case .sent, .sending: label
        default: "Share"
        }
    }

    @ViewBuilder private func shareItems(_ url: URL) -> some View {
        ShareLink(item: url, subject: Text(item.item.title), message: Text(item.item.title)) {
            Text("Share…")
        }
        Button("Copy Link") { ReaderPasteboard.copy(url) }
        Divider()
        if targets.isEmpty {
            Button("Set Up Send To…") { openIntegrationsSettings() }
        } else {
            ForEach(targets) { t in
                Button("Send to \(Self.menuLabel(t))") { Task { await send(to: t) } }
                    .disabled(status == .sending)
            }
        }
    }

    private var icon: some View {
        Group {
            if case .sent = status {
                OFIcon.check.image
                    .foregroundStyle(.ofAccent)
            } else if share != nil {
                OFIcon.share.image
                    .foregroundStyle(Color.ofInk)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .sending)
            } else {
                OFIcon.send.image
                    .foregroundStyle(inSystemToolbar ? AnyShapeStyle(.primary)
                                     : AnyShapeStyle(hovering ? Color.ofInk : Color.ofMuted))
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .sending)
            }
        }
        .font(.system(size: iconSize, weight: .regular))
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering && !inSystemToolbar ? Color.ofHover : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var errorShown: Binding<Bool> {
        Binding(
            get: { if case .error = status { return true } else { return false } },
            set: { if !$0, case .error = status { status = .idle } }
        )
    }

    private func tapped() async {
        guard status != .sending else { return }
        // The first tap can beat the initial load; load rather than guess.
        if targets.isEmpty { await model.loadIntegrations() }
        let current = targets
        if current.isEmpty {
            openIntegrationsSettings()
        } else if current.count == 1 {
            await send(to: current[0])
        }
        // Two targets render the Menu instead of this button.
    }

    private func send(to target: SendTarget) async {
        timer?.cancel()
        status = .sending
        do {
            try await model.send(item, to: target)
            flash(.sent(target), for: .milliseconds(1800))
        } catch {
            flash(.error(HTTP.message(error)), for: .seconds(5))
        }
    }

    private func flash(_ s: Status, for duration: Duration) {
        timer?.cancel()
        status = s
        timer = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { status = .idle }
        }
    }

    private func openIntegrationsSettings() {
        model.showSettings(.integrations)
    }
}
