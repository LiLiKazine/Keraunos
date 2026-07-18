import SwiftUI

/// An inline notice for an error or a required action (e.g. sign-in). A tinted icon tile,
/// a title + body, and up to two stacked actions (a primary button and a ghost link).
/// Semantic color is confined to the icon tile — the card stays on surface-1.
struct NoticeCard: View {
    enum Tone {
        case error, warning
        var color: Color { self == .error ? Color.Theme.error : Color.Theme.warning }
        var symbol: String { self == .error ? "exclamationmark.circle" : "lock" }
    }

    var tone: Tone = .error
    var title: String
    var message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tone.color)
                    .frame(width: 42, height: 42)
                    .background(tone.color.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.Theme.text1)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if primaryTitle != nil || secondaryTitle != nil {
                VStack(spacing: Space.sm) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.primary)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.ghost)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }
}
