import SwiftUI
import KeraunosCore

/// Lists the sites the user is signed into, lets them sign in to a new one, and sign out.
struct AccountsView: View {
    let cookieStore: CookieStore
    @State private var hosts: [String] = []
    @State private var siteText = ""
    @State private var loginTarget: LoginTarget?
    @State private var loginStatus: LoginWebView.LoadStatus = .loading

    /// Identifiable wrapper so the login sheet can be driven by `.sheet(item:)`.
    private struct LoginTarget: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        List {
            Section("Sign in to a site") {
                HStack {
                    TextField("site, e.g. x.com", text: $siteText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Sign in") {
                        if let url = URLNormalizer.normalize(siteText) {
                            loginTarget = LoginTarget(url: url)
                        }
                    }
                    .disabled(siteText.isEmpty)
                }
            }

            if hosts.isEmpty {
                Text("Not signed in to any sites.").foregroundStyle(.secondary)
            } else {
                Section("Signed in") {
                    ForEach(hosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Sign out", role: .destructive) {
                                Task { await cookieStore.signOut(host: host); await reload() }
                            }
                        }
                    }
                }
                Section {
                    Button("Sign out of everything", role: .destructive) {
                        Task { await cookieStore.signOutAll(); await reload() }
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .task { await reload() }
        .sheet(item: $loginTarget) { target in
            NavigationStack {
                LoginWebView(url: target.url, dataStore: cookieStore.dataStore, status: $loginStatus)
                    // Bottom-only: keep the nav bar from overlapping the page's top
                    // content (e.g. the site's login button).
                    .ignoresSafeArea(.container, edges: .bottom)
                    .overlay {
                        if case .failed(let reason) = loginStatus {
                            ContentUnavailableView {
                                Label("Couldn't open \(target.url.host ?? "the page")", systemImage: "wifi.exclamationmark")
                            } description: {
                                Text(reason)
                            }
                        }
                    }
                    .onAppear { loginStatus = .loading }
                    .navigationTitle(target.url.host ?? "Sign in")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { loginTarget = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                loginTarget = nil
                                siteText = ""
                                Task { await reload() }
                            }
                        }
                    }
            }
        }
    }

    private func reload() async {
        hosts = await cookieStore.signedInHosts()
    }
}
