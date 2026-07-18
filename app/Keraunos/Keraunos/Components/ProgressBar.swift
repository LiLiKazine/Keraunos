import SwiftUI

/// A determinate track: surface-2 groove with an accent fill. Height/radius match the
/// design system. Use `ProgressView` spinners for indeterminate work instead.
struct ProgressBar: View {
    /// 0...1. Clamped so a stray value can't overflow the track.
    var value: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Theme.surface2)
                Capsule().fill(Color.Theme.accent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}
