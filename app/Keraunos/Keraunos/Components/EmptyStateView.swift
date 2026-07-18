import SwiftUI

/// A centered empty/placeholder state: an accent-tinted glyph, a title, and a short
/// explanatory line. Used for "no downloads yet", "not signed in", and errors that
/// take over a whole pane.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.Theme.accent)
                .padding(.bottom, Space.xs)
            Text(title)
                .font(.Theme.headline)
                .foregroundStyle(Color.Theme.text1)
            Text(message)
                .font(.Theme.body)
                .foregroundStyle(Color.Theme.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(Space.xl)
    }
}
