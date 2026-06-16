import SwiftUI

/// Lists the sites the user is signed into and lets them sign out.
struct AccountsView: View {
    let cookieStore: CookieStore
    @State private var hosts: [String] = []

    var body: some View {
        List {
            if hosts.isEmpty {
                Text("Not signed in to any sites.").foregroundStyle(.secondary)
            } else {
                Section {
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
    }

    private func reload() async {
        hosts = await cookieStore.signedInHosts()
    }
}
