import SwiftUI

/// A finished-download list row: thumbnail, title + metadata, and a trailing play
/// affordance. Tapping the row plays/previews the file. Metadata is limited to what
/// we can read from disk (size); we don't persist resolution or duration.
struct DownloadRow: View {
    var title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: Space.md) {
            Thumbnail(size: CGSize(width: 62, height: 39), cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.Theme.bodyMedium)
                    .foregroundStyle(Color.Theme.text1)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Theme.text3)
                        .tabularNumbers()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            Image(systemName: "play.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.Theme.accent)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
