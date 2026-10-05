import GitwallAuth
import GitwallCore
import SwiftUI

struct AccountsSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var state: SettingsState
    @State private var showingAdd = false
    @State private var reauthAccount: Account?
    @State private var signInError: String?
    @State private var coordinator = OAuthCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.needsOnboarding {
                welcome
            }
            if environment.isSampleData {
                sampleDataBanner
            }
            List {
                ForEach(environment.config.accounts) { account in
                    AccountRow(
                        account: account,
                        status: environment.snapshot?.accountStatus[account.id],
                        expiresAt: environment.expiry(for: account),
                        usesOAuth: environment.usesOAuth(account),
                        canSignIn: OAuthCoordinator.canSignIn(kind: account.kind, baseURL: account.baseURL),
                        isSample: environment.usesSampleContent,
                        onRepositories: {
                            state.focusedAccountID = account.id
                            state.tab = .repositories
                        },
                        onSignIn: { signIn(account) },
                        onUseToken: { reauthAccount = account },
                        onAddPresets: { environment.addDefaultPresets(for: account) },
                        onRemove: { environment.removeAccount(account) }
                    )
                }
            }
            .listStyle(.inset)
            if let signInError {
                Text(signInError)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        // Signing in again to GitHub shows a code, exactly like adding an account does.
        .sheet(isPresented: Binding(get: { coordinator.deviceCode != nil }, set: { if !$0 { coordinator.cancel() } })) {
            if let code = coordinator.deviceCode {
                DeviceCodeView(code: code) { coordinator.cancel() }
            }
        }
    }

    /// Signs in through the provider and stores the result on `account`, which keeps its repositories, presets and
    /// widgets. Repairs a signed-in account, and moves one that used a token over to signing in.
    private func signIn(_ account: Account) {
        signInError = nil
        Task {
            do {
                // An account that used a token has no client of its own; the built-in one for its host is used.
                let clientID: String? = if case .oauth(let id) = account.authMethod { id } else { nil }
                let result: OAuthCoordinator.Result = switch account.kind {
                case .github: try await coordinator.signInWithGitHub(baseURL: account.baseURL, clientID: clientID)
                case .gitlab: try await coordinator.signInWithGitLab(baseURL: account.baseURL, clientID: clientID, anchor: NSApp.keyWindow)
                }
                try await environment.replaceCredential(for: account, credential: result.token, authMethod: result.authMethod)
            } catch is CancellationError {
                // The user closed the sheet; nothing to report.
            } catch OAuthError.cancelled {
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Gitwall")
                .font(.title2.weight(.semibold))
            Text("Connect a GitHub or GitLab account, pick the repositories you care about, and add the Gitwall widget to your desktop. Pull requests and issues will show up sorted by latest activity.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SampleDataOffer(environment: environment, style: .button)
                .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    /// Sample data replaces the whole configuration in memory, so the way out has to be somewhere that is always
    /// reachable; the accounts tab is where someone goes to connect for real.
    private var sampleDataBanner: some View {
        HStack(spacing: 12) {
            Label("Showing sample data", systemImage: "wand.and.stars")
                .font(.headline)
            Text("Fictional accounts and items. Nothing is saved.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Stop") { environment.leaveSampleData() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12))
    }
}

private struct AccountRow: View {
    let account: Account
    let status: FetchStatus?
    let expiresAt: Date?
    let usesOAuth: Bool
    /// Whether Gitwall can sign in to this account's host without the user registering an application first.
    let canSignIn: Bool
    let isSample: Bool
    let onRepositories: () -> Void
    let onSignIn: () -> Void
    let onUseToken: () -> Void
    let onAddPresets: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.kind == .github ? "cat" : "hare")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.headline)
                HStack(spacing: 6) {
                    Text(account.baseURL.host ?? account.baseURL.absoluteString)
                    Text(isSample ? "sample" : usesOAuth ? "signed in" : "personal access token")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if watchesNothing {
                    // The sync of such an account succeeds with nothing in it, so nothing else would say why.
                    Label("No repositories selected, so nothing is fetched", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("account-no-repositories")
                } else {
                    Text(sourcesDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status, status.state != .ok {
                    Label(status.message ?? status.state.rawValue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let expiryNote {
                    Label(expiryNote, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(expiringSoon ? .orange : .secondary)
                }
            }
            Spacer()
            if needsAttention {
                Button(usesOAuth ? "Sign in again" : "Replace Token…", action: onReauth)
                    .buttonStyle(.borderedProminent)
            }
            if watchesNothing, !needsAttention {
                Button("Choose Repositories…", action: onRepositories)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Repositories…", action: onRepositories)
            }
            Menu {
                Button(usesOAuth ? "Sign in again…" : "Replace Token…", action: onReauth)
                    .disabled(isSample)
                // The other way to sign in, on the same account: repositories, presets and widgets stay.
                if usesOAuth {
                    Button("Use a Token Instead…", action: onUseToken)
                        .disabled(isSample)
                } else if canSignIn {
                    Button("Sign in with \(account.kind == .github ? "GitHub" : "GitLab")…", action: onSignIn)
                        .disabled(isSample)
                }
                Button("Add Default Presets", action: onAddPresets)
                    .help("Assigned pull requests, assigned issues and reviews waiting for you, for this account. Presets you already have are not duplicated.")
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

    private var needsAttention: Bool {
        status?.state == .needsReauth || expiringSoon
    }

    /// Repairing an account uses the way it signs in now.
    private var onReauth: () -> Void { usesOAuth ? onSignIn : onUseToken }

    private var watchesNothing: Bool { account.sources.isEmpty }

    private var expiringSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 7 * 24 * 3600
    }

    private var expiryNote: String? {
        guard let expiresAt else { return nil }
        let when = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return expiresAt.timeIntervalSinceNow <= 0 ? "Token expired on \(when)" : "Token expires on \(when)"
    }

    private var sourcesDescription: String {
        let repos = account.sources.filter { !$0.isDynamic }.count
        let dynamic = account.sources.filter(\.isDynamic).count
        switch (repos, dynamic) {
        case (0, 0): return "No repositories selected yet"
        case (_, 0): return "\(repos) repositories"
        case (0, _): return "\(dynamic) \(account.kind == .gitlab ? "groups" : "organizations")"
        default: return "\(repos) repositories, \(dynamic) \(account.kind == .gitlab ? "groups" : "organizations")"
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
    @State private var clientID = ""
    @State private var showingAdvanced = false
    @State private var usingToken = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var coordinator = OAuthCoordinator()
    @State private var pending: PendingCredential?

    /// A verified credential whose owner is already connected. Nothing is stored until the user says whether it
    /// replaces that account's sign-in or becomes an account of its own.
    private struct PendingCredential {
        let existing: Account
        let kind: ProviderKind
        let baseURL: URL
        let credential: StoredToken
        let authMethod: AuthMethod
    }

    var body: some View {
        // DeviceCodeView and AlreadyConnectedView bring their own padding and width; the form gets them here.
        if let code = coordinator.deviceCode {
            deviceCodeStep(code)
        } else if let pending {
            AlreadyConnectedView(
                account: pending.existing,
                error: error,
                isWorking: isWorking,
                replace: { Task { await resolve(pending, replacing: true) } },
                addSeparately: { Task { await resolve(pending, replacing: false) } },
                cancel: { dismiss() }
            )
        } else {
            form
                .padding(20)
                .frame(width: 460)
        }
    }

    // MARK: - Steps

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.title2.weight(.semibold))

            Picker("Provider", selection: $kind) {
                Text("GitHub").tag(ProviderKind.github)
                Text("GitLab").tag(ProviderKind.gitlab)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, newValue in
                baseURLText = Account.defaultBaseURL(for: newValue).absoluteString
                usingToken = false
                error = nil
            }

            LabeledContent("Server") {
                TextField("https://github.com", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account-base-url")
            }
            .onChange(of: baseURLText) { _, _ in error = nil }

            if canSignIn, !usingToken {
                signInStep
            } else {
                tokenStep
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                SampleDataOffer(environment: environment, explains: false) { dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if canSignIn, !usingToken {
                    Button(isWorking ? "Signing in…" : signInTitle) { Task { await signIn() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || baseURL == nil)
                        .accessibilityIdentifier("account-sign-in")
                } else {
                    Button(isWorking ? "Verifying…" : "Verify and Add") { Task { await addWithToken() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || token.isEmpty || baseURL == nil)
                        .accessibilityIdentifier("account-verify")
                }
            }
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .github
                 ? "Gitwall opens GitHub in your browser and shows a code to confirm. You stay signed in; the token is refreshed in the background."
                 : "Gitwall opens GitLab in a secure window. You stay signed in; the token is refreshed in the background.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use a personal access token instead") { usingToken = true }
                .buttonStyle(.link)
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Token") {
                SecureField("Personal access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account-token")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(scopeHelp).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(tokenLinks, id: \.title) { link in
                    Link(link.title, destination: link.url).font(.caption)
                }
                if canSignIn {
                    Button("Sign in with \(kind == .github ? "GitHub" : "GitLab") instead") { usingToken = false }
                        .buttonStyle(.link)
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Client ID") {
                        TextField("Application client ID", text: $clientID)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("For your own server: register an application there (device flow for GitHub, redirect \(GitLabPKCEFlow.defaultRedirectURI.absoluteString) for GitLab) and paste its client ID to sign in instead of using a token.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !clientID.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Sign in with this client ID") { Task { await signIn() } }
                            .disabled(isWorking || baseURL == nil)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func deviceCodeStep(_ code: DeviceCode) -> some View {
        DeviceCodeView(code: code, error: error) {
            coordinator.cancel()
            dismiss()
        }
    }

    // MARK: - Actions

    private var canSignIn: Bool {
        guard let baseURL else { return false }
        return OAuthCoordinator.canSignIn(kind: kind, baseURL: baseURL)
    }

    private var signInTitle: String {
        kind == .github ? "Sign in with GitHub" : "Sign in with GitLab"
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
        case .github: "Fine-grained token (read-only): set Pull requests, Issues, Commit statuses and Contents to Read-only. It covers one owner, so add one account per organization. Classic token: scopes repo and read:org."
        case .gitlab: "Legacy token with the read_api scope, for gitlab.com and GitLab 16 or newer. GitLab 19.2 or newer also offers fine-grained tokens; the guide lists their permissions and limits."
        }
    }

    private var tokenLinks: [TokenSetupLinks.Link] {
        TokenSetupLinks.links(kind: kind, baseURL: baseURL)
    }

    private func signIn() async {
        guard let baseURL else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let custom = clientID.trimmingCharacters(in: .whitespaces).isEmpty ? nil : clientID.trimmingCharacters(in: .whitespaces)
            let result: OAuthCoordinator.Result = switch kind {
            case .github: try await coordinator.signInWithGitHub(baseURL: baseURL, clientID: custom)
            case .gitlab: try await coordinator.signInWithGitLab(baseURL: baseURL, clientID: custom, anchor: NSApp.keyWindow)
            }
            try await connect(kind: kind, baseURL: baseURL, credential: result.token, authMethod: result.authMethod)
        } catch OAuthError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addWithToken() async {
        guard let baseURL else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let credential = StoredToken(accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), obtainedAt: Date())
            try await connect(kind: kind, baseURL: baseURL, credential: credential, authMethod: .personalAccessToken)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adds the account, unless its owner is already connected: then the user chooses first.
    private func connect(kind: ProviderKind, baseURL: URL, credential: StoredToken, authMethod: AuthMethod) async throws {
        if let existing = try await environment.connectedAccount(kind: kind, baseURL: baseURL, credential: credential) {
            pending = PendingCredential(existing: existing, kind: kind, baseURL: baseURL, credential: credential, authMethod: authMethod)
            return
        }
        try await add(kind: kind, baseURL: baseURL, credential: credential, authMethod: authMethod)
    }

    private func add(kind: ProviderKind, baseURL: URL, credential: StoredToken, authMethod: AuthMethod) async throws {
        let account = try await environment.addAccount(kind: kind, baseURL: baseURL, credential: credential, authMethod: authMethod)
        dismiss()
        onAdded(account)
    }

    private func resolve(_ pending: PendingCredential, replacing: Bool) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            if replacing {
                let account = environment.config.account(id: pending.existing.id) ?? pending.existing
                try await environment.replaceCredential(for: account, credential: pending.credential, authMethod: pending.authMethod)
                dismiss()
            } else {
                try await add(kind: pending.kind, baseURL: pending.baseURL, credential: pending.credential, authMethod: pending.authMethod)
            }
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
            Text(environment.usesOAuth(account) ? "Use a Token for \(account.displayName)" : "Replace Token for \(account.displayName)")
                .font(.title3.weight(.semibold))
            SecureField("New personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if environment.usesOAuth(account) {
                Text("The account keeps its repositories, presets and widgets; only the way it signs in changes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Verifying…" : "Save") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let credential = StoredToken(accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), obtainedAt: Date())
                            try await environment.replaceCredential(for: account, credential: credential, authMethod: .personalAccessToken)
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

/// Add Account found that the owner of the new credential is already connected. Repositories, presets and widgets
/// belong to the account record, so a second record for the same person starts empty; this is where the user
/// learns that before it happens (see `docs/adr/0011`).
struct AlreadyConnectedView: View {
    let account: Account
    var error: String?
    var isWorking = false
    let replace: () -> Void
    let addSeparately: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(account.displayName) is already connected").font(.title2.weight(.semibold))
            Text("This is the same person on the same server. Replacing the sign-in keeps the account with its repositories, presets and widgets. A separate account starts with no repositories and with presets of its own.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add as Separate Account", action: addSeparately)
                    .disabled(isWorking)
                    .accessibilityIdentifier("account-add-separately")
                Button("Replace Sign-In", action: replace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                    .accessibilityIdentifier("account-replace-sign-in")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The GitHub device flow asks the user to type a short code in the browser; this is where they read it.
struct DeviceCodeView: View {
    let code: DeviceCode
    var error: String?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm on GitHub").font(.title2.weight(.semibold))
            Text("Enter this code in the browser window that just opened.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval\u{2026}").foregroundStyle(.secondary)
            }
            Link("Open the page again", destination: code.verificationURI).font(.callout)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
