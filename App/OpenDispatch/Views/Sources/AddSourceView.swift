import OpenDispatchCore
import SwiftUI

/// "Add source" sheet. Port of src/components/add-source.tsx.
/// The URL is normalized first (errors shown inline), then `model.addSource(url:)` detects the feed,
/// stores it and fetches it. Success closes the sheet; failures show the error under the field.
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add source")
                    .font(OFFont.ui(17, .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(.ofInk)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    OFIcon.close.image
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.ofMuted)
                        .frame(width: closeSize, height: closeSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }

            Text("Feed, site, YouTube channel, or podcast URL")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .padding(.top, 12)
            Text("Podcasts: a feed URL or Apple Podcasts link. No feed? A news or blog listing page is scraped for new posts.")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            TextField("example.com/blog, youtube.com/@handle, or a podcast", text: $url)
                .textFieldStyle(.plain)
                .font(OFFont.ui(15))
                .foregroundStyle(.ofBody)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                #endif
                .focused($fieldFocused)
                .onSubmit(submit)
                .disabled(busy)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(fieldFocused ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
                )
                .padding(.top, 6)
                .accessibilityLabel("Feed, site, YouTube channel, or podcast URL")

            if let error {
                Text(error)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(OFFont.ui(14, .medium))
                        .foregroundStyle(.ofInk)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.ofBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: submit) {
                    HStack(spacing: 6) {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(busy ? "Adding..." : "Add")
                    }
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofAccent))
                    .opacity(busy ? 0.6 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(Color.ofSurface)
        .onAppear {
            if let pending = model.pendingAddSourceURL {
                url = pending
                model.pendingAddSourceURL = nil
            }
            fieldFocused = true
        }
        .interactiveDismissDisabled(busy)
    }

    private var closeSize: CGFloat {
        #if os(iOS)
        Metrics.touchTarget
        #else
        Metrics.desktopIconButton
        #endif
    }

    private func submit() {
        guard !busy, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let normalized: String
        do {
            normalized = try SourceURL.normalize(url)
        } catch {
            self.error = HTTP.message(error)
            return
        }
        busy = true
        error = nil
        Task {
            do {
                try await model.addSource(url: normalized)
                url = ""
                busy = false
                dismiss()
            } catch {
                self.error = HTTP.message(error)
                busy = false
            }
        }
    }
}

#Preview {
    AddSourceView().environment(AppModel.preview())
}
