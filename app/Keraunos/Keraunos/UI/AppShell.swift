import SwiftUI

/// The adaptive shell: one `TabView` for every size class. `.sidebarAdaptable` renders it
/// as a bottom tab bar when compact and as a sidebar when regular — a *style* change inside
/// a single container, so nothing is torn down when the size class flips.
///
/// This must stay a single container. An earlier shell branched on the horizontal size class
/// (`if isRegular { NavigationSplitView } else { TabView }`), and on iPhones whose landscape
/// is `.regular` (Pro Max / Plus) rotating swapped the branch, changed view identity, and
/// destroyed the screen subtree — taking any presented player and its `@State` with it.
struct AppShell: View {
    let model: DownloadViewModel
    let cookieStore: CookieStore
    let preferences: Preferences

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selection: AppSection = .download
    @State private var showSettings = false
    @State private var toasts = ToastCenter()
    @State private var downloads = DownloadsViewModel()

    private var isRegular: Bool { hSize == .regular }

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppSection.download.title, systemImage: AppSection.download.symbol, value: AppSection.download) {
                HomeScreen(model: model, downloads: downloads, cookieStore: cookieStore, selection: $selection,
                           onSettings: { showSettings = true })
            }
            .badge(downloads.activeCount == 0 ? 0 : downloads.activeCount)

            Tab(AppSection.library.title, systemImage: AppSection.library.symbol, value: AppSection.library) {
                LibraryScreen(model: model, selection: $selection, onSettings: { showSettings = true })
            }

            Tab(AppSection.accounts.title, systemImage: AppSection.accounts.symbol, value: AppSection.accounts) {
                AccountsScreen(cookieStore: cookieStore, onSettings: { showSettings = true })
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader { brandLockup }
        .tabViewSidebarFooter { settingsEntry }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(model: model, preferences: preferences, showsDoneButton: true)
            }
            .preferredColorScheme(.dark)
        }
        .tint(Color.Theme.accent)
        .preferredColorScheme(.dark)
        .environment(toasts)
        .toastOverlay(toasts, bottomInset: isRegular ? 20 : 96)
    }

    // MARK: - Sidebar chrome (regular width only)

    /// The brand lockup that used to head the hand-built sidebar.
    private var brandLockup: some View {
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
            Spacer()
        }
        .padding(.bottom, Space.sm)
    }

    /// Settings, pinned to the sidebar footer. Opens the same sheet as each screen's gear so
    /// there is one Settings presentation in every size class.
    private var settingsEntry: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 13) {
                Image(systemName: AppSection.settings.symbol).font(.system(size: 18)).frame(width: 22)
                Text(AppSection.settings.title).font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Color.Theme.text2)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
