import SwiftUI
import QuickLook   // provides the .quickLookPreview(_:) view modifier

struct DownloadScreen: View {
    @State private var model: DownloadViewModel
    @State private var showLogin = false
    @State private var loginStatus: LoginWebView.LoadStatus = .loading
    @State private var previewURL: URL?
    let cookieStore: CookieStore

    init(model: DownloadViewModel, cookieStore: CookieStore) {
        _model = State(initialValue: model)
        self.cookieStore = cookieStore
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video link") {
                    HStack {
                        TextField("https://x.com/…", text: $model.urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        // Privacy-friendly one-tap paste (no clipboard-access banner).
                        PasteButton(payloadType: String.self) { items in
                            guard let pasted = items.first else { return }
                            Task { @MainActor in model.urlText = pasted }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Paste link")   // icon-only: announce its purpose
                    }
                    if model.isWorking {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.statusText ?? "Working…")
                                Spacer()
                                Button("Cancel", role: .cancel) { model.cancel() }
                            }
                            if let progress = model.downloadProgress {
                                ProgressView(value: progress)
                                    .accessibilityLabel("Download progress")
                            } else {
                                ProgressView()
                            }
                        }
                    } else {
                        Button("Download") { model.start() }
                            .disabled(model.urlText.isEmpty)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if model.requiresSignIn, let host = model.signInURL?.host {
                            Button("Sign in to \(host)") { showLogin = true }
                        } else if model.canRetry {
                            Button("Try again") { model.start() }
                        }
                    }
                }

                Section("Downloads") {
                    if model.savedFiles.isEmpty {
                        Text("No downloads yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.savedFiles, id: \.self) { file in
                            Button {
                                previewURL = file   // tap to play/preview in-app
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.deletingPathExtension().lastPathComponent)
                                            .lineLimit(1)
                                        if let size = model.fileSizeText(file) {
                                            Text(size).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                                        .accessibilityHidden(true)   // decorative; row reads the title
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays this download")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteDownload(file)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                ShareLink(item: file) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                                if model.canSaveToPhotos(file) {
                                    Button {
                                        Task { await model.saveToPhotos(file) }
                                    } label: {
                                        Label("Save to Photos", systemImage: "arrow.down.to.line")
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }
                    }
                }
                if let logURL = model.failureLogURL {
                    Section("Diagnostics") {
                        ShareLink(item: logURL) {
                            Label("Share failure log", systemImage: "doc.text")
                        }
                        Button("Clear failure log", role: .destructive) {
                            model.clearFailureLog()
                        }
                    }
                }
            }
            .navigationTitle("Keraunos")
            .onOpenURL { model.openIncoming($0) }   // deep link / share / Shortcut entry
            .quickLookPreview($previewURL)
            .alert("Save to Photos", isPresented: Binding(
                get: { model.saveMessage != nil },
                set: { if !$0 { model.dismissSaveMessage() } }
            )) {
                Button("OK", role: .cancel) { model.dismissSaveMessage() }
            } message: {
                Text(model.saveMessage ?? "")
            }
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    if let url = model.signInURL {
                        LoginWebView(url: url, dataStore: cookieStore.dataStore, status: $loginStatus)
                            // Bottom-only: keep the nav bar from overlapping the page's
                            // top content (e.g. the site's login button).
                            .ignoresSafeArea(.container, edges: .bottom)
                            .overlay {
                                // A failed load otherwise shows a blank white page with no
                                // clue why — surface the WebKit error instead.
                                if case .failed(let reason) = loginStatus {
                                    ContentUnavailableView {
                                        Label("Couldn't open \(url.host ?? "the page")", systemImage: "wifi.exclamationmark")
                                    } description: {
                                        Text(reason)
                                    }
                                }
                            }
                            .onAppear { loginStatus = .loading }
                            .navigationTitle(url.host ?? "Sign in")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { showLogin = false }
                                }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showLogin = false
                                        Task { await model.retry() }
                                    }
                                }
                            }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AccountsView(cookieStore: cookieStore)
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
        }
    }
}
