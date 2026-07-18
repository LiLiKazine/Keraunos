import SwiftUI
import WebKit
import KeraunosCore

/// Accounts — the sites the user is signed into (cookies stored on-device only), with
/// add-a-site and sign-out affordances. Wired to `CookieStore`.
struct AccountsScreen: View {
    let cookieStore: CookieStore
    var onSettings: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var hosts: [String] = []
    @State private var siteText = ""
    @State private var loginTarget: LoginTarget?
    @State private var loginStatus: LoginWebView.LoadStatus = .loading

    private struct LoginTarget: Identifiable { let id = UUID(); let url: URL }
    private var isRegular: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if isRegular {
                        PaneTitle(title: "Accounts")
                    } else {
                        CompactHeader(title: "Accounts", onSettings: onSettings)
                    }
                    Text("Sign in to a site to download private, members-only, or age-restricted videos. Keraunos only stores the site’s login cookies on this device.")
                        .font(.Theme.body)
                        .foregroundStyle(Color.Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)

                    addSite
                    signedIn
                    if !hosts.isEmpty { signOutEverything }
                }
                .padding(.horizontal, isRegular ? 4 : 18)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await reload() }
        .sheet(item: $loginTarget, onDismiss: { Task { await reload() } }) { target in
            SiteLoginSheet(url: target.url, dataStore: cookieStore.dataStore,
                           status: $loginStatus, onDone: { siteText = "" })
        }
    }

    private var addSite: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Add a site").sectionLabelStyle()
            HStack(spacing: Space.sm) {
                TextField("site, e.g. youtube.com", text: $siteText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.Theme.text1)
                    .tint(Color.Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
                Button("Sign in") {
                    if let url = URLNormalizer.normalize(siteText) {
                        loginTarget = LoginTarget(url: url)
                    }
                }
                .buttonStyle(.primaryInline)
                .disabled(siteText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        if hosts.isEmpty {
            Text("Not signed in to any sites.")
                .font(.Theme.body)
                .foregroundStyle(Color.Theme.text3)
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Signed in").sectionLabelStyle()
                VStack(spacing: 0) {
                    ForEach(Array(hosts.enumerated()), id: \.element) { index, host in
                        if index > 0 {
                            Rectangle().fill(Color.Theme.hairline).frame(height: Stroke.hairline)
                        }
                        accountRow(host)
                    }
                }
                .card(padding: 0)
            }
        }
    }

    private func accountRow(_ host: String) -> some View {
        HStack(spacing: 13) {
            Monogram(text: host)
            VStack(alignment: .leading, spacing: 2) {
                Text(host).font(.Theme.bodyMedium).foregroundStyle(Color.Theme.text1)
                Text("Signed in").font(.system(size: 11.5)).foregroundStyle(Color.Theme.text3)
            }
            Spacer(minLength: Space.sm)
            Button("Sign out") {
                Task { await cookieStore.signOut(host: host); await reload() }
            }
            .buttonStyle(.ghost)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private var signOutEverything: some View {
        Button {
            Task { await cookieStore.signOutAll(); await reload() }
        } label: {
            Text("Sign out of everything")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Theme.error)
                .frame(maxWidth: isRegular ? 240 : .infinity)
                .padding(.vertical, 14)
                .background(Color.Theme.surface1, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        hosts = await cookieStore.signedInHosts()
    }
}

/// The in-app sign-in web view sheet used from Accounts (add-a-site).
private struct SiteLoginSheet: View {
    let url: URL
    let dataStore: WKWebsiteDataStore
    @Binding var status: LoginWebView.LoadStatus
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(url: url, dataStore: dataStore, status: $status)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay {
                    if case .failed(let reason) = status {
                        ContentUnavailableView {
                            Label("Couldn't open \(url.host ?? "the page")", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(reason)
                        }
                    }
                }
                .onAppear { status = .loading }
                .navigationTitle(url.host ?? "Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(); dismiss() }
                    }
                }
        }
    }
}
