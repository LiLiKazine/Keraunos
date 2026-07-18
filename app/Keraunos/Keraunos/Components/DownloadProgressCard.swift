import SwiftUI

/// The active-download card: source + status, a progress track (or spinner while the
/// size is still unknown), and a Cancel affordance. Only surfaces what the view model
/// actually knows — no fabricated byte-rate or size.
struct DownloadProgressCard: View {
    /// Human status, e.g. "Downloading…", "Resolving…", "Combining…".
    var status: String
    /// Source host parsed from the pasted link, shown as a subtitle. nil hides it.
    var host: String?
    /// 0...1 transfer fraction, or nil when indeterminate (resolving / size unknown).
    var progress: Double?
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                Thumbnail(size: CGSize(width: 50, height: 50), cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status)
                        .font(.Theme.bodyStrong)
                        .foregroundStyle(Color.Theme.text1)
                        .lineLimit(1)
                    if let host {
                        Text(host)
                            .font(.Theme.caption)
                            .foregroundStyle(Color.Theme.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.sm)
                if progress == nil {
                    ProgressView()
                        .tint(Color.Theme.accent)
                }
            }

            if let progress {
                ProgressBar(value: progress)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }

            HStack {
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.Theme.figure)
                        .tabularNumbers()
                        .foregroundStyle(Color.Theme.accent)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.ghost)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.Theme.text3)
            }
        }
        .card()
    }
}
