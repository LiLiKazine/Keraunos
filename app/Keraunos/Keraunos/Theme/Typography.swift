import SwiftUI

/// System-font (SF Pro) type ramp. Sizes match the Foundations board; letter-spacing
/// and casing are applied at the call site via the modifiers below. No custom fonts.
extension Font {
    enum Theme {
        static let display     = Font.system(size: 44, weight: .bold)
        static let screenTitle = Font.system(size: 32, weight: .bold)     // iPhone header
        static let paneTitle   = Font.system(size: 34, weight: .bold)     // iPad content header
        static let title       = Font.system(size: 26, weight: .semibold)
        static let headline    = Font.system(size: 20, weight: .semibold)
        static let body        = Font.system(size: 16, weight: .regular)
        static let bodyMedium  = Font.system(size: 15, weight: .medium)
        static let bodyStrong  = Font.system(size: 15, weight: .semibold)
        static let caption     = Font.system(size: 12.5, weight: .regular)
        static let label       = Font.system(size: 12, weight: .semibold)
        static let figure      = Font.system(size: 16, weight: .medium)   // metrics, tabular
    }
}

extension View {
    /// Uppercase, tracked, tertiary-tinted section label (e.g. "Downloading", "Recent").
    func sectionLabelStyle() -> some View {
        self.font(.Theme.label)
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(Color.Theme.text3)
    }

    /// Tabular figures — use for any numeric readout (sizes, percentages, durations)
    /// so digits don't jitter as they change.
    func tabularNumbers() -> some View {
        self.monospacedDigit()
    }
}
