import SwiftUI

/// The sidebar's source filter (⌘K): narrows the source list by title across every folder, pinned and
/// hidden sources included. Esc clears, unfocuses and closes it; an empty field folds back when focus leaves.
/// Bound to `AppModel.sourceFilter`; `isSourceFilterOpen` is true while the field has focus or text.
struct SidebarFilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            OFIcon.search.image
                .font(.system(size: 12))
                .foregroundStyle(.ofMuted)
                .accessibilityHidden(true)
            TextField("", text: $model.sourceFilter, prompt: Text("Filter sources").foregroundStyle(.ofFaint))
                .textFieldStyle(.plain)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .accessibilityLabel("Filter sources")
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
            if !model.sourceFilter.isEmpty {
                Button {
                    model.sourceFilter = ""
                } label: {
                    OFIcon.close.image
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.ofFaint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.ofCode, in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .strokeBorder(Color.ofAccent.opacity(focused ? 0.6 : 0), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onAppear { if model.isSourceFilterOpen { focused = true } }
        .onChange(of: model.sourceFilterFocusRequests) { _, _ in focused = true }
        .onChange(of: focused) { _, _ in syncOpen() }
        .onChange(of: model.sourceFilter) { _, _ in syncOpen() }
    }

    /// Open while the field has focus or text.
    private func syncOpen() {
        model.isSourceFilterOpen = focused || !model.sourceFilter.isEmpty
    }

    private func close() {
        focused = false
        model.closeSourceFilter()
    }
}
