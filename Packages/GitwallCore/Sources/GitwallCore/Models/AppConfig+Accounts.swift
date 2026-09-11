import Foundation

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

    // MARK: - Private

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
