import SwiftUI

/// Filled call-to-action (accent). Full-width by default (the primary action on a screen);
/// `fullWidth: false` hugs its label for inline use (e.g. the iPad hero row).
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.Theme.onAccent)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 15)
            .padding(.horizontal, fullWidth ? 0 : 22)
            .background(
                (configuration.isPressed ? Color.Theme.accentDim : Color.Theme.accent)
                    .opacity(isEnabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
    }
}

/// Bordered neutral action (surface-2 fill, hairline). Secondary to a primary CTA.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.Theme.text1)
            .padding(.vertical, 13)
            .padding(.horizontal, 22)
            .background(
                Color.Theme.surface2.opacity(configuration.isPressed ? 0.6 : 1),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline)
            )
    }
}

/// Text-only accent action ("See all", "Cancel"). No fill, no border.
struct GhostButtonStyle: ButtonStyle {
    var role: Role = .accent
    enum Role { case accent, destructive }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(role == .destructive ? Color.Theme.error : Color.Theme.accent)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryInline: PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: false) }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
    static var ghostDestructive: GhostButtonStyle { GhostButtonStyle(role: .destructive) }
}
