import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("Request headers")
struct RequestHeaderTests {
    @Test("Every request carries auth, accept, API version and user agent")
    func headers() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user.json"))])
        let provider = GitHubProvider(transport: transport, userAgent: "Gitwall/1.0 tests")
        _ = try await provider.verify(baseURL: github, token: "ghp_secret")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Gitwall/1.0 tests")
    }

    @Test("Default user agent is Gitwall")
    func defaultUserAgent() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user.json"))])
        _ = try await GitHubProvider(transport: transport).verify(baseURL: github, token: "t")
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == "Gitwall")
    }
}

@Suite("verify")
struct VerifyTests {
    @Test("GET /user maps to UserRef")
    func mapsUser() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user.json"))])
        let me = try await GitHubProvider(transport: transport).verify(baseURL: github, token: "t")

        #expect(await transport.requestURLs == [URL(string: "https://api.github.com/user")!])
        #expect(me.login == "prokopsimek")
        #expect(me.displayName == "Prokop Simek")
        #expect(me.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/5487217?v=4")
    }

    @Test("Enterprise base URL hits /api/v3/user")
    func enterprise() async throws {
        let transport = StubTransport([.json(#"{"login":"jane","name":null,"avatar_url":null}"#)])
        let me = try await GitHubProvider(transport: transport).verify(baseURL: URL(string: "https://ghe.example.com/")!, token: "t")
        #expect(await transport.requestURLs == [URL(string: "https://ghe.example.com/api/v3/user")!])
        #expect(me == UserRef(login: "jane"))
    }
}

@Suite("tokenExpiry")
struct TokenExpiryTests {
    @Test("reads the expiry GitHub sends for expiring tokens")
    func expiring() async throws {
        let transport = StubTransport([.json(#"{"login":"me","name":null,"avatar_url":null}"#,
                                             headers: ["GitHub-Authentication-Token-Expiration": "2026-10-01 12:30:00 UTC"])])
        let date = await GitHubProvider(transport: transport).tokenExpiry(baseURL: github, token: "ghp")
        #expect(date == (try Date("2026-10-01T12:30:00Z", strategy: .iso8601)))
    }

    @Test("a token without an expiry header has none, and a rejected token does not raise")
    func noExpiry() async throws {
        let classic = StubTransport([.json(#"{"login":"me","name":null,"avatar_url":null}"#)])
        #expect(await GitHubProvider(transport: classic).tokenExpiry(baseURL: github, token: "ghp") == nil)

        let rejected = StubTransport([.json(#"{"message":"Bad credentials"}"#, status: 401)])
        #expect(await GitHubProvider(transport: rejected).tokenExpiry(baseURL: github, token: "bad") == nil)
    }
}

@Suite("discoverRepositories")
struct DiscoverRepositoriesTests {
    private func repoJSON(_ fullName: String, pushedAt: String, isPrivate: Bool = false, archived: Bool = false, description: String? = nil) -> String {
        let desc = description.map { "\"\($0)\"" } ?? "null"
        return #"{"full_name":"\#(fullName)","description":\#(desc),"private":\#(isPrivate),"archived":\#(archived),"pushed_at":"\#(pushedAt)"}"#
    }

    @Test("Requests /user/repos with the expected parameters")
    func parameters() async throws {
        let transport = StubTransport([.json("[]")])
        _ = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: nil)

        let url = try #require(await transport.requestURLs.first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "api.github.com")
        #expect(components.path == "/user/repos")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["per_page"] == "100")
        #expect(items["sort"] == "pushed")
        #expect(items["affiliation"] == "owner,collaborator,organization_member")
    }

    @Test("Maps the real fixture")
    func mapsFixture() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user_repos_page1.json"))])
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: nil)

        #expect(repos.map(\.fullName) == ["prokopsimek/gitwall", "prokopsimek/chrome-extension-recording"])
        let first = try #require(repos.first)
        #expect(first.isPrivate == false)
        #expect(first.isArchived == false)
        #expect(first.description == nil)
        #expect(first.updatedAt == ISO8601DateFormatter().date(from: "2026-09-10T04:31:51Z"))
        #expect(repos[1].description == "Chrome Extension to record Google Meet meetings")
    }

    @Test("Follows Link rel=next")
    func followsLink() async throws {
        let next = "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner%2Ccollaborator%2Corganization_member&page=2"
        let transport = StubTransport([
            .json("[\(repoJSON("a/one", pushedAt: "2026-09-10T00:00:00Z"))]",
                  headers: ["Link": "<\(next)>; rel=\"next\", <\(next)>; rel=\"last\""]),
            .json("[\(repoJSON("a/two", pushedAt: "2026-09-09T00:00:00Z"))]"),
        ])
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: nil)

        #expect(repos.map(\.fullName) == ["a/one", "a/two"])
        let urls = await transport.requestURLs
        #expect(urls.count == 2)
        #expect(urls[1].absoluteString == next)
        // The follow-up request carries the same headers.
        #expect(await transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test("Stops after five pages")
    func pageCap() async throws {
        let transport = StubTransport()
        for page in 1...7 {
            await transport.enqueue(.json(
                "[\(repoJSON("a/r\(page)", pushedAt: "2026-09-0\(min(page, 9))T00:00:00Z"))]",
                headers: ["Link": "<https://api.github.com/user/repos?page=\(page + 1)>; rel=\"next\""]
            ))
        }
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: nil)
        #expect(await transport.requests.count == 5)
        #expect(repos.count == 5)
    }

    @Test("Filters locally, case-insensitively, on fullName")
    func localFilter() async throws {
        let transport = StubTransport([.json("""
        [\(repoJSON("DXHeroes/mcp-gateway", pushedAt: "2026-09-10T00:00:00Z")),
         \(repoJSON("prokopsimek/gitwall", pushedAt: "2026-09-09T00:00:00Z")),
         \(repoJSON("Applifting/Gateway-Docs", pushedAt: "2026-09-08T00:00:00Z"))]
        """)])
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: "GATEWAY")
        #expect(repos.map(\.fullName) == ["DXHeroes/mcp-gateway", "Applifting/Gateway-Docs"])
    }

    @Test("Blank query means no filter")
    func blankQuery() async throws {
        let transport = StubTransport([.json("[\(repoJSON("a/one", pushedAt: "2026-09-10T00:00:00Z"))]")])
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: "   ")
        #expect(repos.count == 1)
    }

    @Test("Sorted by pushed date, newest first, across pages")
    func sorted() async throws {
        let transport = StubTransport([
            .json("[\(repoJSON("a/old", pushedAt: "2026-01-01T00:00:00Z")), \(repoJSON("a/new", pushedAt: "2026-09-10T00:00:00Z"))]",
                  headers: ["Link": "<https://api.github.com/user/repos?page=2>; rel=\"next\""]),
            .json("[\(repoJSON("a/mid", pushedAt: "2026-05-01T00:00:00Z")), {\"full_name\":\"a/undated\",\"private\":false,\"archived\":true}]"),
        ])
        let repos = try await GitHubProvider(transport: transport).discoverRepositories(baseURL: github, token: "t", query: nil)
        #expect(repos.map(\.fullName) == ["a/new", "a/mid", "a/old", "a/undated"])
        #expect(repos.last?.isArchived == true)
    }
}

@Suite("discoverContainers")
struct DiscoverContainersTests {
    @Test("GET /user/orgs maps to organization sources")
    func mapsOrgs() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user_orgs.json"))])
        let containers = try await GitHubProvider(transport: transport).discoverContainers(baseURL: github, token: "t")

        let url = try #require(await transport.requestURLs.first)
        #expect(url.absoluteString == "https://api.github.com/user/orgs?per_page=100")
        #expect(containers.map(\.id) == ["Revolgy-Business-Solutions", "Applifting", "DXHeroes", "developerexperiencemanifesto"])
        let dxh = try #require(containers.first { $0.id == "DXHeroes" })
        #expect(dxh.name == "DXHeroes")
        #expect(dxh.source == .organization(login: "DXHeroes"))
        #expect(dxh.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/46089594?v=4")
    }

    @Test("Follows Link pagination")
    func pagination() async throws {
        let transport = StubTransport([
            .json(#"[{"login":"one","avatar_url":"https://a/1"}]"#, headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""]),
            .json(#"[{"login":"two","avatar_url":null}]"#),
        ])
        let containers = try await GitHubProvider(transport: transport).discoverContainers(baseURL: github, token: "t")
        #expect(containers.map(\.id) == ["one", "two"])
        #expect(containers[1].avatarURL == nil)
    }
}
