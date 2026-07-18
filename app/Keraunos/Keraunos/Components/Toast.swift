import SwiftUI
import Observation

enum ToastTone { case success, info
    var color: Color { self == .success ? Color.Theme.success : Color.Theme.accent }
}

/// A transient confirmation (download complete, saved to Photos). Identifiable so a new
/// toast replaces the previous one cleanly.
struct ToastData: Identifiable {
    let id = UUID()
    var icon: String
    var tone: ToastTone = .success
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
}

/// App-level channel for toasts so any screen can raise one and the shell renders it in a
/// single, consistent place. Auto-dismisses after a few seconds.
@MainActor @Observable final class ToastCenter {
    private(set) var current: ToastData?
    private var dismissTask: Task<Void, Never>?

    func show(_ toast: ToastData) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [id = toast.id] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled, current?.id == id else { return }
            withAnimation(.easeInOut(duration: 0.25)) { current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { current = nil }
    }
}

/// The toast pill. Sits on surface-2 with a tinted icon and an optional trailing action.
struct ToastView: View {
    let toast: ToastData

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: toast.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(toast.tone.color)
                .frame(width: 38, height: 38)
                .background(toast.tone.color.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.Theme.text1)
                if let subtitle = toast.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Theme.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline)
        )
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
    }
}

extension View {
    /// Renders the toast center's current toast floating near the bottom of the screen.
    /// `bottomInset` lifts it clear of a tab bar (compact) vs. sitting near the edge (regular).
    func toastOverlay(_ center: ToastCenter, bottomInset: CGFloat = 16) -> some View {
        overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastView(toast: toast)
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: center.current?.id)
    }
}
