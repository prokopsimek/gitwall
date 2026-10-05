import Foundation
import Testing
@testable import GitwallCore

@Suite("RepositoryPicker")
struct RepositoryPickerTests {
    private let live = RepoRef(fullName: "acme/app")
    private let old = RepoRef(fullName: "acme/legacy", isArchived: true)
    private let watchedOld = RepoRef(fullName: "acme/retired", isArchived: true)

    @Test("archived repositories are not offered")
    func hidesArchived() {
        let visible = RepositoryPicker.visible([live, old], watched: [], query: "")
        #expect(visible.map(\.fullName) == ["acme/app"])
    }

    @Test("an archived repository that is already watched stays in the list so it can be removed")
    func keepsWatchedArchived() {
        let visible = RepositoryPicker.visible([live, old, watchedOld], watched: ["acme/retired"], query: "")
        #expect(visible.map(\.fullName) == ["acme/app", "acme/retired"])
    }

    @Test("search still matches on the full name, case-insensitively")
    func search() {
        #expect(RepositoryPicker.visible([live, old], watched: [], query: " APP ").map(\.fullName) == ["acme/app"])
        #expect(RepositoryPicker.visible([live, old], watched: [], query: "legacy").isEmpty)
        #expect(RepositoryPicker.visible([live, watchedOld], watched: ["acme/retired"], query: "retired").map(\.fullName) == ["acme/retired"])
    }

    @Test("only explicit repositories count as watched, not organizations or groups")
    func watchedRepositories() {
        let account = Account(
            kind: .github,
            baseURL: URL(string: "https://github.com")!,
            displayName: "GitHub",
            sources: [.repository(fullName: "acme/retired"), .organization(login: "acme"), .group(fullPath: "acme/team", includeSubgroups: true)]
        )
        #expect(RepositoryPicker.watchedRepositories(of: account) == ["acme/retired"])
    }

    @Test("the list is loaded once per account: again when another account is picked or a reload is asked for")
    func loadsOncePerAccount() {
        let github = UUID()
        let gitlab = UUID()
        #expect(RepositoryPicker.shouldLoad(for: github, loaded: nil, force: false))
        #expect(!RepositoryPicker.shouldLoad(for: github, loaded: github, force: false))
        // The reported case: the list of the account shown before must not stand in for this one.
        #expect(RepositoryPicker.shouldLoad(for: github, loaded: gitlab, force: false))
        #expect(RepositoryPicker.shouldLoad(for: github, loaded: github, force: true))
    }
}
