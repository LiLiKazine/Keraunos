import SwiftUI

/// A grid tile for a download: a 16:9 cover with a play glyph (and a progress sliver while
/// downloading), then title + metadata. Used in the Library grid and the iPad Home preview.
struct DownloadTile: View {
    var title: String
    var subtitle: String?
    /// 0...1 while downloading; nil when finished (no progress sliver).
    var progress: Double?
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.Theme.surface2)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.Theme.accent.opacity(0.9))
                    )
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Color.Theme.accent)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 5)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Theme.text1)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Theme.text3)
                        .tabularNumbers()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.Theme.surface1)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Color.Theme.accent : Color.Theme.hairline,
                              lineWidth: isSelected ? 1.5 : Stroke.hairline)
        )
        .cardShadow()
    }
}
