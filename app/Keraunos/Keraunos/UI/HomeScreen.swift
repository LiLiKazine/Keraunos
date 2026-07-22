import SwiftUI
import KeraunosCore

/// The Download screen — paste a link, start a transfer, watch the live queue. A single
/// themed `List` (hero + queue rows) so the unbounded, growing transfer queue renders
/// lazily and terminal rows get native swipe-to-dismiss. Adapts between compact (own
/// header) and regular (nav-bar title, 720pt single reading column). Wired to
/// `DownloadViewModel` (start/quality/sign-in) and `DownloadsViewModel` (the live queue).
struct HomeScreen: View {
    let model: DownloadViewModel
    let downloads: DownloadsViewModel
    let cookieStore: CookieStore
    @Binding var selection: AppSection
    var onSettings: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(ToastCenter.self) private var toasts
    @State private var showLogin = false
    @State private var loginStatus: LoginWebView.LoadStatus = .loading

    private var isRegular: Bool { hSize == .regular }
    private var columnWidth: CGFloat { isRegular ? 720 : .infinity }

    var body: some View {
        List {
            headerRow
            heroCard.plainQueueRow(maxWidth: columnWidth)
            if model.isWorking, let status = model.statusText {
                resolvingRow(status).plainQueueRow(maxWidth: columnWidth)
            }
            if let error = model.errorMessage {
                errorNotice(error).plainQueueRow(maxWidth: columnWidth)
            }
            queueRows
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Color.Theme.bg.ignoresSafeArea())
        .onOpenURL { model.openIncoming($0) }
        .qualityPicker(model: model)
        .loginSheet(model: model, cookieStore: cookieStore, showLogin: $showLogin, loginStatus: $loginStatus)
        .task { downloads.start() }
        .onChange(of: downloads.savedTitles) { _, titles in
            guard !titles.isEmpty else { return }
            if titles.count == 1 {
                toasts.show(ToastData(icon: "checkmark", title: "Saved to Library",
                                      subtitle: titles[0], actionTitle: "Show",
                                      action: { selection = .library }))
            } else {
                toasts.show(ToastData(icon: "checkmark",
                                      title: "\(titles.count) videos saved to Library",
                                      actionTitle: "Show", action: { selection = .library }))
            }
        }
    }

    @ViewBuilder private var headerRow: some View {
        Group {
            if isRegular { PaneTitle(title: "Download") }
            else { CompactHeader(title: "Keraunos", brand: true, onSettings: onSettings) }
        }
        .plainQueueRow(maxWidth: columnWidth)
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

    // MARK: - Resolving

    private func resolvingRow(_ status: String) -> some View {
        HStack(spacing: Space.sm) {
            ProgressView().tint(Color.Theme.accent)
            Text(status).font(.Theme.caption).foregroundStyle(Color.Theme.text3)
            Spacer()
            Button("Cancel") { model.cancel() }.buttonStyle(.ghost)
        }
        .card(padding: 14)
    }

    // MARK: - Error / sign-in notice

    /// The notice's primary action: sign-in beats a retry offer, computed as an if/else
    /// chain rather than a nested ternary.
    private func errorNotice(_ error: String) -> some View {
        let host = model.signInURL?.host
        let signIn = model.requiresSignIn && host != nil

        var primaryTitle: String?
        var primaryAction: (() -> Void)?
        if signIn, let host {
            primaryTitle = "Sign in to \(host)"
            primaryAction = { showLogin = true }
        } else if model.canRetry {
            primaryTitle = "Try again"
            primaryAction = { model.start() }
        }

        var secondaryTitle: String?
        var secondaryAction: (() -> Void)?
        if !signIn, model.failureLogURL != nil {
            secondaryTitle = "Open Settings for diagnostics"
            secondaryAction = { onSettings?() ?? (selection = .settings) }
        }

        return NoticeCard(
            tone: signIn ? .warning : .error,
            title: signIn ? "Sign in required" : "Couldn’t download",
            message: error,
            primaryTitle: primaryTitle,
            primaryAction: primaryAction,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction
        )
    }

    // MARK: - Queue

    @ViewBuilder private var queueRows: some View {
        if downloads.items.isEmpty {
            EmptyStateView(symbol: "arrow.down.to.line",
                           title: "No active downloads",
                           message: "Paste a link above to start. Finished videos move straight to your Library.")
                .frame(maxWidth: .infinity)
                .padding(.top, Space.xl)
                .plainQueueRow(maxWidth: columnWidth)
        } else {
            SectionHeader("Transfers").plainQueueRow(maxWidth: columnWidth)
            ForEach(downloads.items) { item in
                TransferQueueRow(
                    item: item,
                    onPause:  { downloads.pause(item.id) },
                    onResume: { downloads.resume(item.id) },
                    onCancel: { downloads.cancel(item.id) },
                    onRetry:  { downloads.retry(item.id) },
                    onSignIn: { showLogin = true },
                    onManageStorage: { onSettings?() ?? (selection = .settings) },
                    onDismiss: { downloads.dismiss(item.id) })
                .plainQueueRow(maxWidth: columnWidth)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isTerminal(item.rowState) {
                        Button(role: .destructive) { downloads.dismiss(item.id) } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                    }
                }
            }
        }
    }

    private func isTerminal(_ s: TransferRowState) -> Bool {
        if case .failed = s { return true }
        return s == .needsSignIn
    }
}

// MARK: - Row chrome

private extension View {
    /// Chrome-free list row on the theme background with the screen's horizontal inset,
    /// capped at `maxWidth` and left-aligned (iPad's ~720pt single reading column) — makes
    /// a `List` render like a stack of cards while keeping lazy row recycling.
    func plainQueueRow(maxWidth: CGFloat = .infinity) -> some View {
        self
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: Space.xs, leading: 20, bottom: Space.xs, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
