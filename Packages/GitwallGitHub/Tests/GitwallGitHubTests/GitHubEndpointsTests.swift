import Foundation
import Testing
@testable import GitwallGitHub

@Suite("GitHubEndpoints")
struct GitHubEndpointsTests {
    @Test("github.com maps to api.github.com", arguments: [
        "https://github.com",
        "https://github.com/",
        "https://GitHub.com/prokopsimek/gitwall",
        "https://www.github.com",
        "https://api.github.com",
    ])
    func cloud(base: String) throws {
        let endpoints = GitHubEndpoints(baseURL: try #require(URL(string: base)))
        #expect(endpoints.rest.absoluteString == "https://api.github.com")
        #expect(endpoints.graphQL.absoluteString == "https://api.github.com/graphql")
    }

    @Test("GitHub Enterprise Server uses /api/v3 and /api/graphql", arguments: [
        "https://ghe.example.com",
        "https://ghe.example.com/",
        "https://ghe.example.com/some/path/",
    ])
    func enterprise(base: String) throws {
        let endpoints = GitHubEndpoints(baseURL: try #require(URL(string: base)))
        #expect(endpoints.rest.absoluteString == "https://ghe.example.com/api/v3")
        #expect(endpoints.graphQL.absoluteString == "https://ghe.example.com/api/graphql")
    }

    @Test("Enterprise keeps scheme and port")
    func enterprisePort() throws {
        let endpoints = GitHubEndpoints(baseURL: try #require(URL(string: "http://ghe.local:8080/")))
        #expect(endpoints.rest.absoluteString == "http://ghe.local:8080/api/v3")
        #expect(endpoints.graphQL.absoluteString == "http://ghe.local:8080/api/graphql")
    }

    @Test("REST paths append without double slashes")
    func restPath() throws {
        let endpoints = GitHubEndpoints(baseURL: try #require(URL(string: "https://ghe.example.com/")))
        #expect(endpoints.rest.appendingPathComponent("user").absoluteString == "https://ghe.example.com/api/v3/user")
    }
}

@Suite("GitHubProvider capabilities")
struct GitHubProviderCapabilitiesTests {
    @Test func capabilities() {
        let provider = GitHubProvider()
        #expect(provider.kind == .github)
        #expect(provider.capabilities.pullRequestTerm == "Pull request")
        #expect(provider.capabilities.pullRequestAbbreviation == "PR")
        #expect(provider.capabilities.supportsOrganizationSources)
        #expect(!provider.capabilities.supportsGroupSources)
        #expect(!provider.capabilities.resolvesTeamReviewRequests)
    }
}
