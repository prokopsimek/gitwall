import Foundation

/// Why a preset that shows no items shows none.
public enum PresetEmptiness: Equatable, Sendable {
    /// None of the accounts the preset looks at watches anything, so nothing was fetched for it. Carries the
    /// first of them, the one to send the user to.
    case nothingWatched(Account)
    /// Items are fetched and none pass the preset. `idle` is an account of the preset that watches nothing, when
    /// there is one: its items would be missing whatever the filter says.
    case nothingMatches(idle: Account?)
}

/// How accounts and their default presets enter and leave a configuration. Pure functions, so the rules are tested
/// here instead of living in the app target.
extension AppConfig {
    /// Adds `account` with its three default presets. A configuration without any presets also gets the shared
    /// ``Preset/defaults()`` first. The review preset shows its count in the menu bar only if no preset does yet.
    public func adding(_ account: Account, pullRequestTerm: String) -> AppConfig {
        var updated = self
        var added = account
        added.defaultPresetsCreated = true
        updated.accounts.append(added)
        if updated.presets.isEmpty {
            updated.presets = Preset.defaults()
        }
        updated.presets += updated.defaultPresets(for: added, pullRequestTerm: pullRequestTerm)
        return updated
    }

    /// Creates the default presets, once, for accounts saved before per-account presets existed.
    /// Accounts already marked are left alone, so presets the user deleted do not come back.
    public func seedingDefaultPresets(pullRequestTerm: (ProviderKind) -> String) -> AppConfig {
        var updated = self
        for index in updated.accounts.indices where updated.accounts[index].defaultPresetsCreated != true {
            updated.accounts[index].defaultPresetsCreated = true
            let account = updated.accounts[index]
            updated.presets += updated.defaultPresets(for: account, pullRequestTerm: pullRequestTerm(account.kind))
        }
        return updated
    }

    /// "Add Default Presets" from the account menu: adds only the defaults the configuration does not already have,
    /// matched by what they select rather than by name.
    public func addingDefaultPresets(for accountID: UUID, pullRequestTerm: String) -> AppConfig {
        guard let account = account(id: accountID) else { return self }
        var updated = self
        let missing = defaultPresets(for: account, pullRequestTerm: pullRequestTerm).filter { candidate in
            !presets.contains { $0.isEquivalent(to: candidate) }
        }
        updated.presets += missing
        return updated
    }

    /// Removes the account and everything that only existed for it. Presets scoped to this account alone are
    /// deleted; presets shared with other accounts lose just this account's scope. Without that, a preset whose
    /// only scope disappeared would silently widen to every account.
    public func removing(accountID: UUID) -> AppConfig {
        var updated = self
        updated.accounts.removeAll { $0.id == accountID }
        updated.presets = updated.presets.compactMap { preset in
            guard preset.scopes.contains(where: { $0.accountID == accountID }) else { return preset }
            var narrowed = preset
            narrowed.scopes.removeAll { $0.accountID == accountID }
            return narrowed.scopes.isEmpty ? nil : narrowed
        }
        return updated
    }

    // MARK: - Recognising an account

    /// The one account a freshly verified credential already belongs to: same provider, same server, same login,
    /// however that account signs in. Watched repositories, presets and widgets hang on the account record, so a
    /// second sign-in by the same person should replace the credential of that record instead of starting an
    /// empty twin. Several accounts under one login are deliberate (one fine-grained token per organization), and
    /// then there is no single account to offer (see `docs/adr/0011`).
    public func replaceableAccount(kind: ProviderKind, baseURL: URL, login: String) -> Account? {
        let server = Self.server(baseURL)
        let matches = accounts.filter { account in
            account.kind == kind
                && Self.server(account.baseURL) == server
                && account.me?.login.caseInsensitiveCompare(login) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Accounts that fetch nothing

    /// The accounts a preset looks at that watch no repository, organization or group. Such an account fetches
    /// nothing and still syncs successfully, so the app has to name it instead of showing an empty list.
    public func idleAccounts(visibleTo preset: Preset) -> [Account] {
        accounts(visibleTo: preset).filter(\.sources.isEmpty)
    }

    /// Why a preset that shows no items shows none.
    public func emptiness(of preset: Preset) -> PresetEmptiness {
        let visible = accounts(visibleTo: preset)
        let idle = visible.filter(\.sources.isEmpty)
        if let first = idle.first, idle.count == visible.count { return .nothingWatched(first) }
        return .nothingMatches(idle: idle.first)
    }

    // MARK: - Private

    private func accounts(visibleTo preset: Preset) -> [Account] {
        guard !preset.scopes.isEmpty else { return accounts }
        return accounts.filter { account in preset.scopes.contains { $0.accountID == account.id } }
    }

    /// Host, port and path of a base URL, without the scheme, the case of the host or a trailing slash.
    private static func server(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host)\(port)/\(path)"
    }

    private func defaultPresets(for account: Account, pullRequestTerm: String) -> [Preset] {
        let countTaken = presets.contains(where: \.showCountInMenuBar)
        return Preset.accountDefaults(
            for: account,
            label: account.shortLabel(among: accounts),
            pullRequestTerm: pullRequestTerm,
            showCountInMenuBar: !countTaken
        )
    }
}
