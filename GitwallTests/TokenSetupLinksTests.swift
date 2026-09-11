import Foundation
import GitwallCore
@testable import Gitwall
import Testing

/// The token pages are prefilled through URL parameters that the hosts document; a typo silently drops a permission.
@Suite("Token setup links")
struct TokenSetupLinksTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("github.com offers a prefilled read-only fine-grained token, a classic token and the guide")
    func githubCloud() throws {
        let links = TokenSetupLinks.links(kind: .github, baseURL: URL(string: "https://github.com"))
        #expect(links.map(\.title) == ["Create a fine-grained token…", "Create a classic token…", "Token setup guide"])

        let fineGrained = links[0].url
        #expect(fineGrained.host == "github.com")
        #expect(fineGrained.path == "/settings/personal-access-tokens/new")
        let params = query(fineGrained)
        #expect(params["name"] == "Gitwall")
        #expect(params["expires_in"] == "365")
        #expect(params["pull_requests"] == "read")
        #expect(params["issues"] == "read")
        #expect(params["statuses"] == "read")
        // Without Contents GitHub hides the commit, and with it the CI state, from fine-grained tokens.
        #expect(params["contents"] == "read")
        #expect(params.filter { $0.value == "write" }.isEmpty)

        #expect(links[1].url.absoluteString == "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Gitwall")
        #expect(links[2].url.absoluteString == "https://github.com/prokopsimek/gitwall#personal-access-tokens")
    }

    @Test("GitHub Enterprise Server gets the classic token page on its own host")
    func githubEnterprise() {
        let links = TokenSetupLinks.links(kind: .github, baseURL: URL(string: "https://github.example.com/"))
        #expect(links.map(\.title) == ["Create a classic token…", "Token setup guide"])
        #expect(links[0].url.absoluteString == "https://github.example.com/settings/tokens/new?scopes=repo,read:org&description=Gitwall")
    }

    @Test("GitLab gets the prefilled read_api token page on its own host")
    func gitlab() {
        let links = TokenSetupLinks.links(kind: .gitlab, baseURL: URL(string: "https://git.example.com"))
        #expect(links.map(\.title) == ["Create a token on GitLab…", "Token setup guide"])
        #expect(links[0].url.absoluteString == "https://git.example.com/-/user_settings/personal_access_tokens?name=Gitwall&scopes=read_api")
    }

    @Test("without a valid server only the guide is offered")
    func noBaseURL() {
        #expect(TokenSetupLinks.links(kind: .gitlab, baseURL: nil).map(\.title) == ["Token setup guide"])
    }
}
