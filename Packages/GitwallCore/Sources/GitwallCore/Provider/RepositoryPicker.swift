import Foundation

/// What the repository picker offers. Archived repositories are left out: nothing in them can be merged or
/// closed, and the providers drop their items anyway. One that is already watched stays in the list, otherwise
/// it could never be unticked.
public enum RepositoryPicker {
    public static func visible(_ repositories: [RepoRef], watched: Set<String>, query: String) -> [RepoRef] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repositories.filter { repo in
            guard !repo.isArchived || watched.contains(repo.fullName) else { return false }
            return needle.isEmpty || repo.fullName.lowercased().contains(needle)
        }
    }

    /// Full names of the repositories an account watches explicitly. Organizations and groups are dynamic and
    /// have no entry in the picker's list.
    public static func watchedRepositories(of account: Account) -> Set<String> {
        Set(account.sources.compactMap { source in
            if case .repository(let fullName) = source { return fullName }
            return nil
        })
    }
}
