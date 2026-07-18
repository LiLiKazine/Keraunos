import SwiftUI
import KeraunosCore

/// Settings — reached from the gear (compact) or the sidebar footer (regular). Every control
/// reflects real state or behavior: the two preferences change how downloads resolve/save,
/// storage/diagnostics read the device, and About shows build facts. No decorative switches.
struct SettingsView: View {
    let model: DownloadViewModel
    @Bindable var preferences: Preferences
    /// True when shown as a modal (compact) so it gets a Done button; false as a detail pane.
    var showsDoneButton: Bool = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    downloadsGroup
                    appearanceGroup
                    storageGroup
                    aboutGroup
                }
                .padding(.horizontal, 18)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var downloadsGroup: some View {
        SettingsGroup(title: "Downloads") {
            Menu {
                Picker("Default quality", selection: $preferences.defaultQuality) {
                    ForEach(DefaultQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                SettingsRow(icon: "slider.horizontal.3", label: "Default quality") {
                    HStack(spacing: 6) {
                        Text(preferences.defaultQuality.label).foregroundStyle(Color.Theme.text3)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                            .foregroundStyle(Color.Theme.text3)
                    }
                }
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.Theme.hairline)
            SettingsRow(icon: "photo.on.rectangle", label: "Save to Photos automatically") {
                Toggle("", isOn: $preferences.autoSaveToPhotos)
                    .labelsHidden()
                    .tint(Color.Theme.accent)
            }
        }
    }

    private var appearanceGroup: some View {
        SettingsGroup(title: "Appearance") {
            SettingsRow(icon: "moon.stars", label: "Theme") {
                Text("Dark").foregroundStyle(Color.Theme.text3)
            }
        }
    }

    private var storageGroup: some View {
        SettingsGroup(title: "Storage") {
            SettingsRow(icon: "internaldrive", label: "Downloads on this device") {
                Text(model.totalDownloadsSizeText)
                    .tabularNumbers()
                    .foregroundStyle(Color.Theme.text1)
                    .fontWeight(.semibold)
            }
            if model.failureLogURL != nil {
                Divider().overlay(Color.Theme.hairline)
                ShareLink(item: model.failureLogURL!) {
                    SettingsRow(icon: "doc.text", label: "Share diagnostics log") {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15))
                            .foregroundStyle(Color.Theme.text3)
                    }
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.Theme.hairline)
                Button {
                    model.clearFailureLog()
                } label: {
                    SettingsRow(label: "Clear diagnostics log", destructive: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutGroup: some View {
        SettingsGroup(title: "About") {
            SettingsRow(label: "Version") {
                Text(Self.versionString).tabularNumbers().foregroundStyle(Color.Theme.text3)
            }
            Divider().overlay(Color.Theme.hairline)
            SettingsRow(label: "Extraction engine") {
                Text("yt-dlp").foregroundStyle(Color.Theme.text3)
            }
            Divider().overlay(Color.Theme.hairline)
            SettingsRow(label: "License") {
                Text("GPLv3").foregroundStyle(Color.Theme.text3)
            }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// A titled group of settings rows on a surface-1 card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).sectionLabelStyle().padding(.leading, 6)
            VStack(spacing: 0) { content() }
                .card(padding: 0)
        }
    }
}

/// One settings row: optional accent icon tile, a label, and trailing content (value,
/// toggle, chevron, …). `destructive` tints the label for a delete-style action.
private struct SettingsRow<Trailing: View>: View {
    var icon: String?
    let label: String
    var destructive: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Color.Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            }
            Text(label)
                .font(.system(size: 15.5))
                .foregroundStyle(destructive ? Color.Theme.error : Color.Theme.text1)
            Spacer(minLength: Space.sm)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
