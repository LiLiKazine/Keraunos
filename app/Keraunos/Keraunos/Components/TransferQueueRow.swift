import SwiftUI
import KeraunosCore

/// One queue row. The header (thumbnail + title + source·quality) is shared; the body and
/// actions switch on the nine `TransferRowState`s from the design's `TransferStates.dc.html`.
/// Terminal rows put their primary recovery inline (Retry / Sign in / Manage storage).
struct TransferQueueRow: View {
    let item: QueueItem
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onManageStorage: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        switch item.rowState {
        case .failed(let reason): failedCard(reason)
        case .needsSignIn:        signInCard
        default:                  standardCard
        }
    }

    // MARK: Active / paused / queued / waiting / merging / refreshing

    private var standardCard: some View {
        VStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                Thumbnail(size: CGSize(width: 50, height: 50), cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.Theme.bodyStrong).foregroundStyle(Color.Theme.text1).lineLimit(1)
                    Text(subtitle).font(.Theme.caption).foregroundStyle(Color.Theme.text3).lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                trailingControls
            }
            if showsBar { bar }
            statusLine
        }
        .card()
    }

    private var subtitle: String {
        [item.sourceHost, item.qualityLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// Determinate bar for downloading/paused; indeterminate for waiting/merging/refreshing.
    private var showsBar: Bool {
        switch item.rowState {
        case .downloading, .paused, .waitingBackground, .merging, .refreshing: return true
        case .queued, .needsSignIn, .failed: return false
        }
    }

    @ViewBuilder private var bar: some View {
        if let fraction = item.fraction, item.rowState == .downloading || item.rowState == .paused {
            ProgressBar(value: fraction)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
        } else {
            IndeterminateBar()   // waiting/merging/refreshing, or size not yet known
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack {
            Text(statusText).font(.Theme.figure).tabularNumbers().foregroundStyle(statusColor)
            Spacer()
        }
    }

    private var statusText: String {
        switch item.rowState {
        case .downloading:
            if let f = item.fraction { return "\(Int(f * 100))%" }
            return "Downloading…"
        case .paused:
            return item.fraction.map { "Paused · \(Int($0 * 100))%" } ?? "Paused"
        case .queued:             return "◷ Queued · \(item.qualityLabel)"
        case .waitingBackground:  return "Waiting to resume…"
        case .merging:            return "Merging video + audio…"
        case .refreshing:         return "Refreshing link…"
        case .needsSignIn, .failed: return ""
        }
    }

    private var statusColor: Color {
        item.rowState == .downloading ? Color.Theme.accent : Color.Theme.text3
    }

    @ViewBuilder private var trailingControls: some View {
        switch item.rowState {
        case .downloading:
            iconButton("pause.fill", action: onPause)
            iconButton("xmark", action: onCancel)
        case .paused:
            iconButton("play.fill", action: onResume)
            iconButton("xmark", action: onCancel)
        case .queued:
            iconButton("xmark", action: onCancel)
        case .waitingBackground:
            iconButton("xmark", action: onCancel)
        case .merging, .refreshing, .needsSignIn, .failed:
            EmptyView()   // automatic or handled by the notice card
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Theme.text2)
                .frame(width: 34, height: 34)
                .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Needs sign-in

    private var signInCard: some View {
        NoticeCard(tone: .warning, title: "Sign in to continue",
                   message: "\(item.title) needs you to sign in to \(item.sourceHost ?? "this site").",
                   primaryTitle: "Sign in to \(item.sourceHost ?? "site")", primaryAction: onSignIn,
                   secondaryTitle: "Remove", secondaryAction: onDismiss)
    }

    // MARK: Failed (network / no-space / other)

    private func failedCard(_ reason: FailureReason) -> some View {
        let (title, message, primaryTitle, primaryAction): (String, String, String, () -> Void) = {
            switch reason {
            case .insufficientSpace:
                return ("Not enough storage",
                        "\(item.title) needs more space than is available.",
                        "Manage storage", onManageStorage)
            case .network:
                return ("Couldn’t finish — network", "\(item.title) stopped downloading.", "Retry", onRetry)
            case .refreshFailed:
                return ("Couldn’t refresh link", "The download link for \(item.title) expired and couldn’t be renewed.", "Retry", onRetry)
            case .integrityCheckFailed:
                return ("File check failed", "The downloaded data for \(item.title) was incomplete.", "Retry", onRetry)
            }
        }()
        return NoticeCard(tone: .error, title: title, message: message,
                          primaryTitle: primaryTitle, primaryAction: primaryAction,
                          secondaryTitle: "Dismiss", secondaryAction: onDismiss)
    }
}

/// An indeterminate progress bar matching `ProgressBar`'s track, for waiting/merging/refreshing.
private struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Theme.surface2)
                Capsule().fill(Color.Theme.accent)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: (geo.size.width * 1.35) * phase - geo.size.width * 0.35)
            }
        }
        .frame(height: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
