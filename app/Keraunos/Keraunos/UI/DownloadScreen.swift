import SwiftUI

struct DownloadScreen: View {
    @State private var model: DownloadViewModel
    @State private var showLogin = false
    let cookieStore: CookieStore

    init(model: DownloadViewModel, cookieStore: CookieStore) {
        _model = State(initialValue: model)
        self.cookieStore = cookieStore
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video link") {
                    TextField("https://x.com/…", text: $model.urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await model.startDownload() }
                    } label: {
                        if model.isWorking {
                            HStack { ProgressView(); Text(model.statusText ?? "Working…") }
                        } else {
                            Text("Download")
                        }
                    }
                    .disabled(model.isWorking || model.urlText.isEmpty)
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if model.requiresSignIn, let host = model.signInURL?.host {
                            Button("Sign in to \(host)") { showLogin = true }
                        }
                    }
                }

                Section("Downloads") {
                    if model.savedFiles.isEmpty {
                        Text("No downloads yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.savedFiles, id: \.self) { file in
                            Text(file.lastPathComponent)
                        }
                    }
                }
            }
            .navigationTitle("Keraunos")
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    if let url = model.signInURL {
                        LoginWebView(url: url, dataStore: cookieStore.dataStore)
                            .ignoresSafeArea()
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
        }
    }
}
