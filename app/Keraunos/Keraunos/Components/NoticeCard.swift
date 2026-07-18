import SwiftUI

/// An inline notice for an error or a required action (e.g. sign-in). Semantic color is
/// a small icon tint only — the card itself stays on surface-1. An optional action
/// button renders as a secondary control beneath the message.
struct NoticeCard: View {
    enum Tone {
        case error, warning
        var color: Color {
            switch self {
            case .error:   Color.Theme.error
            case .warning: Color.Theme.warning
            }
        }
        var symbol: String {
            switch self {
            case .error:   "exclamationmark.triangle.fill"
            case .warning: "person.badge.key.fill"
            }
        }
    }

    var tone: Tone = .error
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.sm + 2) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.Theme.body)
                    .foregroundStyle(Color.Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
