import SwiftUI
import QuickLook
import KeraunosCore

/// The Download screen — paste a link, start a transfer, watch progress, reach recent
/// downloads. Adapts between compact (own header, stacked hero, Recent list) and regular
/// (nav-bar title, inline hero, Library preview grid). Wired to `DownloadViewModel`.
struct HomeScreen: View {
    let model: DownloadViewModel
    let cookieStore: CookieStore
    @Binding var selection: AppSection
    var onSettings: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(ToastCenter.self) private var toasts
    @State private var showLogin = false
    @State private var loginStatus: LoginWebView.LoadStatus = .loading
    @State private var previewURL: URL?
    @State private var pendingDelete: URL?

    private var isRegular: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if isRegular {
                        PaneTitle(title: "Download")
                    } else {
                        CompactHeader(title: "Keraunos", brand: true, onSettings: onSettings)
                    }
                    heroCard
                    if model.isWorking { downloadingSection }
                    if let error = model.errorMessage { errorNotice(error) }
                    contentSection
                }
                .padding(.horizontal, 20)
                .padding(.top, isRegular ? Space.xs : Space.sm)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onOpenURL { model.openIncoming($0) }
        .quickLookPreview($previewURL)
        .qualityPicker(model: model)
        .loginSheet(model: model, cookieStore: cookieStore, showLogin: $showLogin, loginStatus: $loginStatus)
        .deleteConfirmation($pendingDelete, model: model, toasts: toasts)
        .saveMessageToast(model: model, toasts: toasts)
        .onChange(of: model.lastSavedName) { _, name in
            guard name != nil, let newest = model.savedFiles.first else { return }
            toasts.show(ToastData(
                icon: "checkmark", title: "Download complete",
                subtitle: newest.deletingPathExtension().lastPathComponent,
                actionTitle: "View", action: { previewURL = newest }))
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Paste a video link").sectionLabelStyle()
            if isRegular {
                HStack(spacing: Space.md) {
                    LinkPasteField(text: Binding(get: { model.urlText }, set: { model.urlText = $0 }))
                    downloadButton
                        .buttonStyle(.primaryInline)
                }
            } else {
                LinkPasteField(text: Binding(get: { model.urlText }, set: { model.urlText = $0 }))
                downloadButton
                    .buttonStyle(.primary)
            }
        }
        .card(padding: 18)
    }

    private var downloadButton: some View {
        Button {
            model.start()
        } label: {
            Label("Download", systemImage: "arrow.down.to.line")
        }
        .disabled(model.urlText.isEmpty || model.isWorking)
    }

    // MARK: - Downloading

    private var downloadingSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Downloading")
            DownloadProgressCard(
                status: model.statusText ?? "Working…",
                host: URLNormalizer.normalize(model.urlText)?.host,
                progress: model.downloadProgress,
                onCancel: { model.cancel() }
            )
        }
    }

    // MARK: - Error / sign-in notice

    private func errorNotice(_ error: String) -> some View {
        let host = model.signInURL?.host
        let signIn = model.requiresSignIn && host != nil
        return NoticeCard(
            tone: signIn ? .warning : .error,
            title: signIn ? "Sign in required" : "Couldn’t download",
            message: error,
            primaryTitle: signIn ? "Sign in to \(host!)" : (model.canRetry ? "Try again" : nil),
            primaryAction: signIn ? { showLogin = true } : (model.canRetry ? { model.start() } : nil),
            secondaryTitle: (!signIn && model.failureLogURL != nil) ? "Open Settings for diagnostics" : nil,
            secondaryAction: (!signIn && model.failureLogURL != nil) ? { onSettings?() ?? (selection = .settings) } : nil
        )
    }

    // MARK: - Recent (compact) / Library preview (regular) / first-run

    @ViewBuilder
    private var contentSection: some View {
        if model.savedFiles.isEmpty {
            if !model.isWorking && model.errorMessage == nil {
                firstRunEmpty
            }
        } else if isRegular {
            libraryPreviewGrid
        } else {
            recentList
        }
    }

    private var firstRunEmpty: some View {
        EmptyStateView(
            symbol: "arrow.down.to.line",
            title: "Your first download",
            message: "Copy a video link from any site, paste it above, and Keraunos pulls it straight to your device."
        )
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xl)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Recent") {
                Button("See all") { selection = .library }
                    .buttonStyle(.ghost)
            }
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element) { index, file in
                    if index > 0 {
                        Rectangle().fill(Color.Theme.hairline).frame(height: Stroke.hairline)
                    }
                    recentRow(file)
                }
            }
        }
    }

    private var libraryPreviewGrid: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SectionHeader("Library") {
                Button("See all") { selection = .library }
                    .buttonStyle(.ghost)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.lg)], spacing: Space.lg) {
                ForEach(recent, id: \.self) { file in
                    Button { previewURL = file } label: {
                        DownloadTile(title: file.deletingPathExtension().lastPathComponent,
                                     subtitle: model.librarySubtitle(file), progress: nil)
                    }
                    .buttonStyle(.plain)
                    .downloadContextMenu(file: file, model: model,
                                         onPlay: { previewURL = file },
                                         onDelete: { pendingDelete = file })
                }
            }
        }
    }

    /// The most recent handful for the Home preview; the full set lives in Library.
    private var recent: [URL] { Array(model.savedFiles.prefix(6)) }

    private func recentRow(_ file: URL) -> some View {
        Button {
            previewURL = file
        } label: {
            DownloadRow(title: file.deletingPathExtension().lastPathComponent,
                        subtitle: model.librarySubtitle(file))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this download")
        .downloadContextMenu(file: file, model: model,
                             onPlay: { previewURL = file },
                             onDelete: { pendingDelete = file })
    }
}
