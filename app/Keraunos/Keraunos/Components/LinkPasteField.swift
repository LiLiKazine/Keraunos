import SwiftUI

/// The link entry row: a URL text field with a privacy-friendly one-tap Paste button
/// (no clipboard-access banner) that becomes a clear button once text is present.
/// Sits on surface-2 so it reads as an inset inside a surface-1 hero card.
struct LinkPasteField: View {
    @Binding var text: String
    var placeholder: String = "https://youtube.com/watch?v=…"

    var body: some View {
        HStack(spacing: Space.sm) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 15))
                .foregroundStyle(Color.Theme.text1)
                .tint(Color.Theme.accent)

            if text.isEmpty {
                PasteButton(payloadType: String.self) { items in
                    guard let pasted = items.first else { return }
                    Task { @MainActor in text = pasted }
                }
                .labelStyle(.titleAndIcon)
                .tint(Color.Theme.accent)
                .buttonBorderShape(.roundedRectangle(radius: Radius.chip))
                .accessibilityLabel("Paste link")
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.Theme.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear link")
                .padding(.trailing, 11)
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
    }
}
