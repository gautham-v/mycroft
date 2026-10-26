import SwiftUI

/// The sidebar's source search box (⌘K), styled like the Claude Code sidebar's: narrows the source list
/// by title across every folder, pinned and hidden sources included. Closed, it is a button drawn as
/// the box, so nothing takes keyboard focus at launch; clicking it (or ⌘K) puts a focused text field
/// in the same place. Esc clears and closes it; an empty field closes when focus leaves.
/// Bound to `AppModel.sourceFilter`; `isSourceFilterOpen` is true while the field has focus or text.
struct SidebarFilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.isSourceFilterOpen {
                field
            } else {
                Button { model.openSourceFilter() } label: {
                    box {
                        Text("Search")
                            .font(OFFont.sidebarRow)
                            .foregroundStyle(.ofMuted)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .help("Search sources (⌘K)")
                .accessibilityLabel("Search sources")
            }
        }
        .onChange(of: model.sourceFilterFocusRequests) { _, _ in focused = true }
    }

    private var field: some View {
        @Bindable var model = model
        return box {
            TextField("", text: $model.sourceFilter, prompt: Text("Search").foregroundStyle(.ofMuted))
                .textFieldStyle(.plain)
                .font(OFFont.sidebarRow)
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .accessibilityLabel("Search sources")
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
                        .foregroundStyle(.ofMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .onAppear { focused = true }
        .onChange(of: focused) { _, _ in syncOpen() }
        .onChange(of: model.sourceFilter) { _, _ in syncOpen() }
    }

    /// The rounded box: magnifier in the row icon column, so the text lines up with the row labels.
    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            OFIcon.search.image
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.ofMuted)
                .frame(width: SidebarStyle.iconColumn)
                .accessibilityHidden(true)
            content()
        }
        .padding(.leading, SidebarStyle.rowPadding)
        .padding(.trailing, 6)
        .frame(height: Metrics.sidebarRowHeight)
        .background(Color.ofField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.ofBorder : Color.ofHairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
