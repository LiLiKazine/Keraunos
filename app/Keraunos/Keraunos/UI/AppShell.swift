import SwiftUI

/// The adaptive shell. Compact width → a bottom `TabView` (Settings behind each screen's
/// gear). Regular width → a `NavigationSplitView` with a custom sidebar (Settings in the
/// footer). Same screens, same tokens — only the container changes with the size class.
struct AppShell: View {
    let model: DownloadViewModel
    let cookieStore: CookieStore
    let preferences: Preferences

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selection: AppSection = .download
    @State private var showSettings = false
    @State private var toasts = ToastCenter()

    private var isRegular: Bool { hSize == .regular }

    var body: some View {
        Group {
            if isRegular { splitLayout } else { tabLayout }
        }
        .tint(Color.Theme.accent)
        .preferredColorScheme(.dark)
        .environment(toasts)
        .toastOverlay(toasts, bottomInset: isRegular ? 20 : 96)
    }

    // MARK: - Compact: tab bar

    private var tabLayout: some View {
        TabView(selection: $selection) {
            HomeScreen(model: model, cookieStore: cookieStore, selection: $selection,
                       onSettings: { showSettings = true })
                .tabItem { Label(AppSection.download.title, systemImage: AppSection.download.symbol) }
                .tag(AppSection.download)
            LibraryScreen(model: model, selection: $selection, onSettings: { showSettings = true })
                .tabItem { Label(AppSection.library.title, systemImage: AppSection.library.symbol) }
                .tag(AppSection.library)
            AccountsScreen(cookieStore: cookieStore, onSettings: { showSettings = true })
                .tabItem { Label(AppSection.accounts.title, systemImage: AppSection.accounts.symbol) }
                .tag(AppSection.accounts)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(model: model, preferences: preferences, showsDoneButton: true)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Regular: sidebar split

    private var splitLayout: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            NavigationStack {
                detail
                    // Titles are rendered in-content (PaneTitle) beside the split-view
                    // toggle, per the design; keep the bar itself empty but present.
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color.Theme.bg, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .download:
            HomeScreen(model: model, cookieStore: cookieStore, selection: $selection, onSettings: nil)
        case .library:
            LibraryScreen(model: model, selection: $selection, onSettings: nil)
        case .accounts:
            AccountsScreen(cookieStore: cookieStore, onSettings: nil)
        case .settings:
            SettingsView(model: model, preferences: preferences, showsDoneButton: false)
        }
    }
}

/// The iPad sidebar: brand lockup, the primary destinations as accent pills, and Settings
/// pinned to the footer.
private struct SidebarView: View {
    @Binding var selection: AppSection

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
                    Text("Keraunos")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.Theme.text1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, Space.lg)

                ForEach(AppSection.primary) { section in
                    navItem(section)
                }
                Spacer()
                navItem(.settings)
            }
            .padding(16)
        }
    }

    private func navItem(_ section: AppSection) -> some View {
        Button { selection = section } label: {
            HStack(spacing: 13) {
                Image(systemName: section.symbol).font(.system(size: 18)).frame(width: 22)
                Text(section.title).font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(selection == section ? Color.Theme.accent : Color.Theme.text2)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                selection == section ? Color.Theme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
