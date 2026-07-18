import SwiftUI

extension View {
    /// The two-layer card shadow from the design system: a tight contact shadow plus a
    /// soft ambient one. Kept subtle — depth, not glow.
    func cardShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
    }

    /// Wraps content in a surface-1 card: hairline border, given corner radius, card shadow.
    func card(radius: CGFloat = Radius.card, padding: CGFloat = Space.lg) -> some View {
        self
            .padding(padding)
            .background(Color.Theme.surface1, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline)
            )
            .cardShadow()
    }
}
