import SwiftUI
import UIKit

/// The link entry row: a URL text field with a privacy-friendly one-tap Paste button
/// (no clipboard-access banner). The Paste button stays available once text is present —
/// it shrinks to icon-only and replaces the field's contents — and a clear button joins it.
/// It dims out whenever the clipboard holds no text to paste.
/// Sits on surface-2 so it reads as an inset inside a surface-1 hero card.
struct LinkPasteField: View {
    @Binding var text: String
    var placeholder: String = "https://youtube.com/watch?v=…"

    /// Whether the clipboard currently holds text. `hasStrings` is a *presence* check —
    /// unlike reading `.string` it never surfaces the "pasted from…" banner.
    @State private var canPaste = UIPasteboard.general.hasStrings

    var body: some View {
        HStack(spacing: Space.sm) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 15))
                .foregroundStyle(Color.Theme.text1)
                .tint(Color.Theme.accent)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.Theme.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear link")

                pasteButton
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Replace link with pasted link")
            } else {
                pasteButton
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Paste link")
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 16)
        .padding(.trailing, 5)
        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline)
        )
        // `changedNotification` covers copies made while we're foregrounded; the
        // activation hook catches a clipboard changed in another app meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPasteAvailability()
        }
    }

    /// Overwrites whatever is in the field — pasting is always "replace", never "append".
    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { items in
            guard let pasted = items.first else { return }
            Task { @MainActor in text = pasted }
        }
        .tint(Color.Theme.accent)
        .buttonBorderShape(.roundedRectangle(radius: Radius.chip))
        .disabled(!canPaste)
        .opacity(canPaste ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: canPaste)
    }

    private func refreshPasteAvailability() {
        canPaste = UIPasteboard.general.hasStrings
    }
}
