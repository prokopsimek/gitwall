import GitwallCore
import SwiftUI

struct RepositoriesSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var state: SettingsState

    @State private var selectedAccountID: UUID?
    @State private var repositories: [RepoRef] = []
    @State private var containers: [ContainerRef] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var manualEntry = ""

    private var account: Account? {
        environment.config.account(id: selectedAccountID ?? UUID()) ?? environment.config.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.config.accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add an account first, then choose which repositories Gitwall should watch.")
                )
            } else if let account {
                header(account)
                Divider()
                content(account)
            }
        }
        .task(id: account?.id) { await load() }
        .onAppear {
            if let focused = state.focusedAccountID {
                selectedAccountID = focused
                state.focusedAccountID = nil
            }
        }
        .onChange(of: state.focusedAccountID) { _, newValue in
            if let newValue {
                selectedAccountID = newValue
                state.focusedAccountID = nil
            }
        }
    }

    private func header(_ account: Account) -> some View {
        HStack {
            if environment.config.accounts.count > 1 {
                Picker("Account", selection: Binding(
                    get: { account.id },
                    set: { selectedAccountID = $0 }
                )) {
                    ForEach(environment.config.accounts) { Text($0.displayName).tag($0.id) }
                }
                .frame(maxWidth: 280)
            } else {
                Text(account.displayName).font(.headline)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload repositories from the server")
        }
        .padding(12)
    }

    private func content(_ account: Account) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search repositories", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 12)
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
                }
                List {
                    if !containers.isEmpty {
                        Section(account.kind == .gitlab ? "Groups (all projects, including subgroups and new ones)" : "Organizations (all repositories, including new ones)") {
                            ForEach(containers) { container in
                                Toggle(isOn: sourceBinding(container.source, account: account)) {
                                    Label(container.name, systemImage: "building.2")
                                }
                            }
                        }
                    }
                    Section(repositories.isEmpty ? (account.kind == .gitlab ? "Projects" : "Repositories") : "\(account.kind == .gitlab ? "Projects" : "Repositories") (\(filteredRepositories.count))") {
                        if repositories.isEmpty, !isLoading {
                            Text("No repositories found for this token. You can add one manually on the right.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredRepositories) { repo in
                            Toggle(isOn: sourceBinding(.repository(fullName: repo.fullName), account: account)) {
                                VStack(alignment: .leading) {
                                    HStack(spacing: 4) {
                                        Text(repo.fullName)
                                        if repo.isPrivate { Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary) }
                                        if repo.isArchived { Text("archived").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    if let description = repo.description, !description.isEmpty {
                                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                Text("Watched sources").font(.headline)
                if account.sources.isEmpty {
                    Text("Nothing selected. Tick repositories or organizations on the left, or add one manually.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                List {
                    ForEach(account.sources, id: \.self) { source in
                        HStack {
                            Image(systemName: source.isDynamic ? "building.2" : "folder")
                            Text(source.displayName).lineLimit(1)
                            Spacer()
                            Button {
                                setSource(source, enabled: false, account: account)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset)
                HStack {
                    TextField(account.kind == .gitlab ? "group/project" : "owner/repository", text: $manualEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addManual(account) }
                    Button("Add") { addManual(account) }
                        .disabled(!isValidManualEntry)
                }
                Text("Manual entries work when the token can read the repository but discovery does not list it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(minWidth: 240)
        }
    }

    private var filteredRepositories: [RepoRef] {
        let watched = account.map(RepositoryPicker.watchedRepositories) ?? []
        return RepositoryPicker.visible(repositories, watched: watched, query: search)
    }

    private var isValidManualEntry: Bool {
        let parts = manualEntry.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        let allowed = account?.kind == .gitlab ? parts.count >= 2 : parts.count == 2
        return allowed && parts.allSatisfy { !$0.isEmpty }
    }

    private func addManual(_ account: Account) {
        guard isValidManualEntry else { return }
        setSource(.repository(fullName: manualEntry.trimmingCharacters(in: .whitespaces)), enabled: true, account: account)
        manualEntry = ""
    }

    private func sourceBinding(_ source: RepoSource, account: Account) -> Binding<Bool> {
        Binding(
            get: { (environment.config.account(id: account.id) ?? account).sources.contains(source) },
            set: { setSource(source, enabled: $0, account: account) }
        )
    }

    private func setSource(_ source: RepoSource, enabled: Bool, account: Account) {
        guard var current = environment.config.account(id: account.id) else { return }
        current.sources.removeAll { $0 == source }
        if enabled { current.sources.append(source) }
        environment.updateAccount(current)
    }

    private func load(force: Bool = false) async {
        guard let account, let provider = environment.provider(for: account) else { return }
        if !force, !repositories.isEmpty { return }
        // Sample accounts have no token; list what discovery would find so the tab works the same way.
        if environment.usesSampleContent {
            (repositories, containers) = DemoData.discovery(for: account.id)
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            guard let token = try environment.tokenStore.token(for: account.id)?.accessToken else {
                loadError = "No token stored for this account."
                return
            }
            async let repos = provider.discoverRepositories(baseURL: account.baseURL, token: token, query: nil)
            async let orgs = provider.discoverContainers(baseURL: account.baseURL, token: token)
            repositories = try await repos
            containers = try await orgs
        } catch {
            loadError = error.localizedDescription
        }
    }
}
