import SwiftUI
import QuickLook
import KeraunosCore

/// The Download screen — paste a link, start a transfer, watch progress, and reach
/// recent downloads. Rebuilt in the "Refined Native" system; wired to the existing
/// `DownloadViewModel` (behavior unchanged from the PoC `DownloadScreen`).
struct HomeScreen: View {
    @State private var model: DownloadViewModel
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var loginStatus: LoginWebView.LoadStatus = .loading
    @State private var previewURL: URL?
    let cookieStore: CookieStore

    init(model: DownloadViewModel, cookieStore: CookieStore) {
        _model = State(initialValue: model)
        self.cookieStore = cookieStore
    }

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    heroCard
                    if model.isWorking { downloadingSection }
                    if let error = model.errorMessage { errorNotice(error) }
                    recentSection
                }
                .padding(.horizontal, 20)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xxl)
            }
        }
        .onOpenURL { model.openIncoming($0) }
        .quickLookPreview($previewURL)
        .qualityPicker(model: model)
        .saveToPhotosAlert(model: model)
        .loginSheet(model: model, cookieStore: cookieStore, showLogin: $showLogin, loginStatus: $loginStatus)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(model: model) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.Theme.accent)
                    .accessibilityHidden(true)
                Text("Keraunos")
                    .font(.Theme.screenTitle)
                    .foregroundStyle(Color.Theme.text1)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.Theme.text2)
                    .frame(width: 38, height: 38)
                    .background(Color.Theme.surface2, in: Circle())
                    .overlay(Circle().strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, Space.sm)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Paste a video link").sectionLabelStyle()
            LinkPasteField(text: $model.urlText)
            Button {
                model.start()
            } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.primary)
            .disabled(model.urlText.isEmpty || model.isWorking)
        }
        .card(padding: 18)
    }

    // MARK: - Downloading

    private var downloadingSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Downloading")
            DownloadProgressCard(
                status: model.statusText ?? "Working…",
                host: sourceHost,
                progress: model.downloadProgress,
                onCancel: { model.cancel() }
            )
        }
    }

    // MARK: - Error / sign-in

    private func errorNotice(_ error: String) -> some View {
        let host = model.signInURL?.host
        let signInAction = model.requiresSignIn && host != nil
        return NoticeCard(
            tone: model.requiresSignIn ? .warning : .error,
            message: error,
            actionTitle: signInAction ? "Sign in to \(host!)" : (model.canRetry ? "Try again" : nil),
            action: signInAction ? { showLogin = true } : (model.canRetry ? { model.start() } : nil)
        )
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Recent")
            if model.savedFiles.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No downloads yet",
                    message: "Paste a link above and Keraunos pulls the best stream to your device."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, Space.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.savedFiles.enumerated()), id: \.element) { index, file in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.Theme.hairline)
                                .frame(height: Stroke.hairline)
                        }
                        recentRow(file)
                    }
                }
            }
        }
    }

    private func recentRow(_ file: URL) -> some View {
        Button {
            previewURL = file
        } label: {
            DownloadRow(
                title: file.deletingPathExtension().lastPathComponent,
                subtitle: model.fileSizeText(file)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this download")
        .contextMenu {
            ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
            if model.canSaveToPhotos(file) {
                Button {
                    Task { await model.saveToPhotos(file) }
                } label: {
                    Label("Save to Photos", systemImage: "arrow.down.to.line")
                }
            }
            Button(role: .destructive) {
                model.deleteDownload(file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var sourceHost: String? {
        URLNormalizer.normalize(model.urlText)?.host
    }
}
