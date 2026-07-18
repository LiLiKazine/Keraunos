import SwiftUI
import KeraunosCore

/// Settings, reached from the gear in the Home header (and the sidebar footer on iPad).
/// Minimal for now — carries the diagnostics affordance that used to live on the Home
/// Form; the full Settings screen (per the Settings board) lands in a later step.
struct SettingsView: View {
    let model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    about
                    if let logURL = model.failureLogURL {
                        diagnostics(logURL)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, Space.lg)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("About")
            HStack(spacing: Space.md) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keraunos").font(.Theme.headline).foregroundStyle(Color.Theme.text1)
                    Text("Download anything. Fast as lightning.")
                        .font(.Theme.caption).foregroundStyle(Color.Theme.text3)
                }
                Spacer(minLength: 0)
            }
            .card()
        }
    }

    private func diagnostics(_ logURL: URL) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Diagnostics")
            VStack(alignment: .leading, spacing: Space.md) {
                Text("A log of recent extraction failures, useful for reporting a broken site.")
                    .font(.Theme.body)
                    .foregroundStyle(Color.Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.md) {
                    ShareLink(item: logURL) {
                        Label("Share log", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.secondary)
                    Button("Clear", role: .destructive) { model.clearFailureLog() }
                        .buttonStyle(.ghostDestructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}
