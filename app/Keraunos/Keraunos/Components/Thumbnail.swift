import SwiftUI

/// Placeholder artwork for a video. We don't extract poster frames, so this is a
/// surface-2 tile with a hairline and a centered accent play glyph — a consistent,
/// honest stand-in wherever a thumbnail would go (progress card, list row, grid tile).
struct Thumbnail: View {
    var size: CGSize
    var cornerRadius: CGFloat
    var symbol: String = "play.fill"

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.Theme.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: min(size.width, size.height) * 0.34))
                    .foregroundStyle(Color.Theme.accent)
            )
            .frame(width: size.width, height: size.height)
    }
}
