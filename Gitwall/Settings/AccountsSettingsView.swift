import GitwallCore
import SwiftUI

struct AccountsSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var state: SettingsState
    @State private var showingAdd = false
    @State private var reauthAccount: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.needsOnboarding {
                welcome
            }
            List {
                ForEach(environment.config.accounts) { account in
                    AccountRow(
                        account: account,
                        status: environment.snapshot?.accountStatus[account.id],
                        onRepositories: {
                            state.focusedAccountID = account.id
                            state.tab = .repositories
                        },
                        onReauth: { reauthAccount = account },
                        onRemove: { environment.removeAccount(account) }
                    )
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .accessibilityIdentifier("add-account")
                Spacer()
                Text("Tokens are stored in the macOS Keychain and never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingAdd) {
            AddAccountSheet(environment: environment) { account in
                state.focusedAccountID = account.id
                state.tab = .repositories
            }
        }
        .sheet(item: $reauthAccount) { account in
            ReplaceTokenSheet(environment: environment, account: account)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Gitwall")
                .font(.title2.weight(.semibold))
            Text("Connect a GitHub account, pick the repositories you care about, and add the Gitwall widget to your desktop. Pull requests and issues will show up sorted by latest activity.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }
}

private struct AccountRow: View {
    let account: Account
    let status: FetchStatus?
    let onRepositories: () -> Void
    let onReauth: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.kind == .github ? "cat" : "fossil.shell")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.headline)
                Text(account.baseURL.host ?? account.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourcesDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status, status.state != .ok {
                    Label(status.message ?? status.state.rawValue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Repositories…", action: onRepositories)
            Menu {
                Button("Replace Token…", action: onReauth)
                Divider()
                Button("Remove Account", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 4)
    }

    private var sourcesDescription: String {
        let repos = account.sources.filter { !$0.isDynamic }.count
        let dynamic = account.sources.filter(\.isDynamic).count
        switch (repos, dynamic) {
        case (0, 0): return "No repositories selected yet"
        case (_, 0): return "\(repos) repositories"
        case (0, _): return "\(dynamic) organizations"
        default: return "\(repos) repositories, \(dynamic) organizations"
        }
    }
}

struct AddAccountSheet: View {
    @Bindable var environment: AppEnvironment
    var onAdded: (Account) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ProviderKind = .github
    @State private var baseURLText = "https://github.com"
    @State private var token = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.title2.weight(.semibold))

            Picker("Provider", selection: $kind) {
                Text("GitHub").tag(ProviderKind.github)
                Text("GitLab (coming soon)").tag(ProviderKind.gitlab)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, newValue in
                baseURLText = Account.defaultBaseURL(for: newValue).absoluteString
            }

            LabeledContent("Server") {
                TextField("https://github.com", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account-base-url")
            }
            Text("For GitHub Enterprise Server or a self-hosted GitLab, enter the web address of your instance.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Token") {
                SecureField("Personal access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account-token")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(scopeHelp).font(.caption).foregroundStyle(.secondary)
                if kind == .github, let url = tokenURL {
                    Link("Create a token on GitHub…", destination: url).font(.caption)
                }
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Verifying…" : "Verify and Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || token.isEmpty || baseURL == nil || kind == .gitlab)
                    .accessibilityIdentifier("account-verify")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var baseURL: URL? {
        var text = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return nil
        }
        return url
    }

    private var scopeHelp: String {
        switch kind {
        case .github: "Classic token: scopes repo and read:org. Fine-grained token: read access to Pull requests, Issues, Metadata (and Members for organizations)."
        case .gitlab: "GitLab support with read_api tokens arrives in the next update."
        }
    }

    private var tokenURL: URL? {
        guard let baseURL else { return nil }
        return URL(string: "\(baseURL.absoluteString)/settings/tokens/new?scopes=repo,read:org&description=Gitwall")
    }

    private func add() async {
        guard let baseURL else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let account = try await environment.addAccount(kind: kind, baseURL: baseURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
            onAdded(account)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReplaceTokenSheet: View {
    @Bindable var environment: AppEnvironment
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace Token for \(account.displayName)").font(.title3.weight(.semibold))
            SecureField("New personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Verifying…" : "Save") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await environment.replaceToken(for: account, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
