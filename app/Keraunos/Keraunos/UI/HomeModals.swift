import SwiftUI
import KeraunosCore

/// Sheets and dialogs shared by the Download flow, kept out of `HomeScreen.body` for
/// readability. Each reads its presented state directly off the observable view model.
extension View {
    /// Quality chooser. A confirmation dialog for now — a chip-based sheet lands with
    /// the QualityPicker screen. `titleVisibility` keeps the "Choose quality" heading.
    func qualityPicker(model: DownloadViewModel) -> some View {
        confirmationDialog(
            "Choose quality",
            isPresented: Binding(
                get: { model.pendingOptions != nil },
                set: { if !$0 { model.cancelSelection() } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(model.pendingOptions ?? [], id: \.formatID) { option in
                Button(option.displayLabel) { model.selectFormat(option) }
            }
            Button("Cancel", role: .cancel) { model.cancelSelection() }
        }
    }

    /// One-off result of a Save-to-Photos attempt.
    func saveToPhotosAlert(model: DownloadViewModel) -> some View {
        alert("Save to Photos", isPresented: Binding(
            get: { model.saveMessage != nil },
            set: { if !$0 { model.dismissSaveMessage() } }
        )) {
            Button("OK", role: .cancel) { model.dismissSaveMessage() }
        } message: {
            Text(model.saveMessage ?? "")
        }
    }

    /// In-app sign-in web view for the site behind an auth wall. On dismiss with "Done"
    /// the download is retried with the freshly captured cookies.
    func loginSheet(
        model: DownloadViewModel,
        cookieStore: CookieStore,
        showLogin: Binding<Bool>,
        loginStatus: Binding<LoginWebView.LoadStatus>
    ) -> some View {
        sheet(isPresented: showLogin) {
            NavigationStack {
                if let url = model.signInURL {
                    LoginWebView(url: url, dataStore: cookieStore.dataStore, status: loginStatus)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .overlay {
                            if case .failed(let reason) = loginStatus.wrappedValue {
                                ContentUnavailableView {
                                    Label("Couldn't open \(url.host ?? "the page")", systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text(reason)
                                }
                            }
                        }
                        .onAppear { loginStatus.wrappedValue = .loading }
                        .navigationTitle(url.host ?? "Sign in")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showLogin.wrappedValue = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showLogin.wrappedValue = false
                                    Task { await model.retry() }
                                }
                            }
                        }
                }
            }
        }
    }
}
