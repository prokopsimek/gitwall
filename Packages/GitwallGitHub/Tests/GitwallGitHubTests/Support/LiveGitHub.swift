import Foundation
import GitwallCore
@testable import GitwallGitHub

/// What the suites that run against GitHub.com share: the token, the repositories and an account over them.
enum LiveGitHub {
    static let isEnabled = ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] != nil
    static let token = ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] ?? ""
    static let baseURL = URL(string: "https://github.com")!

    /// `GITWALL_GITHUB_REPO`, several repositories separated by commas, or `cli/cli` when it is unset or empty.
    static let repositories: [String] = {
        let listed = (ProcessInfo.processInfo.environment["GITWALL_GITHUB_REPO"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return listed.isEmpty ? ["cli/cli"] : listed
    }()

    /// One `.repository` source per repository, and the token owner as `me`, read with the same identity call the app
    /// makes when the account is added. `me` is what `@me` and the relations mean locally, and what resolves a review
    /// request to one of the owner's teams.
    static func account(provider: GitHubProvider) async throws -> Account {
        let me = try await provider.verify(baseURL: baseURL, token: token)
        return Account(kind: .github, baseURL: baseURL, displayName: "GitHub", me: me,
                       sources: repositories.map { .repository(fullName: $0) })
    }

    /// The repositories as the query's sources, one `repo:` term each.
    static var sources: [String] { repositories.map { "repo:\($0)" } }

    /// Counts only, because the repositories may belong to the token owner.
    static var repositoryCount: String {
        repositories.count == 1 ? "1 repository" : "\(repositories.count) repositories"
    }
}
