import Foundation
import GitwallCore

/// Token pages prefilled with Gitwall's name and read-only permissions, plus the setup guide in the README.
enum TokenSetupLinks {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    static func links(kind: ProviderKind, baseURL: URL?) -> [Link] {
        var links: [Link?] = []
        if let baseURL {
            let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch kind {
            case .github:
                // Only github.com is known to prefill fine-grained tokens; Enterprise Server gets the classic page.
                if baseURL.host?.lowercased() == "github.com" {
                    links.append(link("Create a fine-grained token…", "\(base)/settings/personal-access-tokens/new?\(fineGrainedGitHubQuery)"))
                }
                links.append(link("Create a classic token…", "\(base)/settings/tokens/new?scopes=repo,read:org&description=Gitwall"))
            case .gitlab:
                links.append(link("Create a token on GitLab…", "\(base)/-/user_settings/personal_access_tokens?name=Gitwall&scopes=read_api"))
            }
        }
        links.append(link("Token setup guide", Links.tokenGuide))
        return links.compactMap { $0 }
    }

    /// GitHub caps fine-grained tokens at 365 days; a longer `expires_in` falls back to 30. The CI state needs both
    /// Commit statuses and Contents: without Contents GitHub hides the commit that carries it.
    private static let fineGrainedGitHubQuery = [
        "name=Gitwall",
        "description=Read-only%20access%20for%20the%20Gitwall%20widgets",
        "expires_in=365",
        "pull_requests=read",
        "issues=read",
        "statuses=read",
        "contents=read",
    ].joined(separator: "&")

    private static func link(_ title: String, _ string: String) -> Link? {
        URL(string: string).map { Link(title: title, url: $0) }
    }
}
