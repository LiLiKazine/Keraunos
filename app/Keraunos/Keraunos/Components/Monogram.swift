import SwiftUI

/// An accent-tinted rounded tile showing a host's first letter — the avatar stand-in for
/// a signed-in site in the Accounts list.
struct Monogram: View {
    var text: String
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.Theme.accentSoft)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(Color.Theme.accent)
            )
    }

    private var initial: String {
        guard let first = text.first else { return "•" }
        return String(first).uppercased()
    }
}
