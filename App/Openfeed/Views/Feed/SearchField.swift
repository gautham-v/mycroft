import SwiftUI

/// The list's search input (search-field.tsx). `.desktop` sits in the 54pt list header (30pt tall,
/// 14pt text); `.phone` is a full-width 44pt row under the phone title (16pt text).
/// Esc clears and closes; Enter commits right away and leaves the field so j/k work on results;
/// an empty field folds back into the search button when focus leaves it.
/// Bound to `AppModel.searchDraft`, which commits after 250 ms (use-search.ts).
struct FeedSearchField: View {
    enum Variant { case desktop, phone }

    @Environment(AppModel.self) private var model
    let variant: Variant
    var focus: FocusState<Bool>.Binding

    private var phone: Bool { variant == .phone }
    private var isEmpty: Bool { model.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            OFIcon.search.image
                .font(.system(size: phone ? 16 : 13))
                .foregroundStyle(.ofMuted)
                .accessibilityHidden(true)
            TextField("", text: $model.searchDraft, prompt: Text(model.searchPlaceholder).foregroundStyle(.ofFaint))
                .textFieldStyle(.plain)
                .font(OFFont.ui(phone ? 16 : 14))
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused(focus)
                .padding(.horizontal, phone ? 8 : 6)
                .accessibilityLabel("Search items")
                .onSubmit {
                    model.flushSearch()
                    focus.wrappedValue = false
                }
                #if os(macOS)
                .onExitCommand { close() }
                #endif
            Button(action: { isEmpty ? close() : model.clearSearch() }) {
                OFIcon.close.image
                    .font(.system(size: phone ? 16 : 13))
                    .frame(width: phone ? Metrics.touchTarget : Metrics.desktopIconButton,
                           height: phone ? Metrics.touchTarget : Metrics.desktopIconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FeedHoverIconButtonStyle(inkOnHover: true, hoverBackground: false))
            .accessibilityLabel(isEmpty ? "Close search" : "Clear search")
        }
        .padding(.leading, phone ? 12 : 8)
        .frame(height: phone ? Metrics.touchTarget : Metrics.desktopIconButton)
        .frame(maxWidth: .infinity)
        .background(Color.ofCode, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.ofAccent.opacity(focus.wrappedValue ? 0.6 : 0), lineWidth: 1)
        )
        .onChange(of: focus.wrappedValue) { _, focused in
            // An empty field folds back into the search button when focus leaves it.
            if !focused, isEmpty, model.isSearchOpen { model.closeSearch() }
        }
    }

    private func close() {
        focus.wrappedValue = false
        model.closeSearch()
    }
}

/// Plain icon button for the list headers: muted icon that turns ink on hover (desktop), with an
/// optional rounded hover background (`hover:bg-[var(--hover)]`).
struct FeedHoverIconButtonStyle: ButtonStyle {
    var inkOnHover = true
    var hoverBackground = true
    var baseColor: Color = .ofMuted

    func makeBody(configuration: Configuration) -> some View {
        FeedHoverIconLabel(configuration: configuration, inkOnHover: inkOnHover,
                           hoverBackground: hoverBackground, baseColor: baseColor)
    }
}

private struct FeedHoverIconLabel: View {
    let configuration: ButtonStyleConfiguration
    let inkOnHover: Bool
    let hoverBackground: Bool
    let baseColor: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(hovering && inkOnHover && isEnabled ? Color.ofInk : baseColor)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoverBackground && isEnabled && (hovering || configuration.isPressed) ? Color.ofHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}
