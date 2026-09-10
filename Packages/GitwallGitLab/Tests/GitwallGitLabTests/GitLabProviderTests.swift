import Foundation
import GitwallCore
import Testing
@testable import GitwallGitLab

private let cloud = URL(string: "https://gitlab.com")!
private let selfHosted = URL(string: "https://git.applifting.cz")!

private func account(_ sources: [RepoSource], baseURL: URL = selfHosted, me: String = "prokopsimek") -> Account {
    Account(kind: .gitlab, baseURL: baseURL, displayName: "GitLab", me: UserRef(login: me), sources: sources)
}

@Suite("GitLabEndpoints")
struct GitLabEndpointsTests {
    @Test("REST and GraphQL endpoints derive from the web base URL", arguments: [
        ("https://gitlab.com", "https://gitlab.com/api/v4", "https://gitlab.com/api/graphql"),
        ("https://git.applifting.cz/", "https://git.applifting.cz/api/v4", "https://git.applifting.cz/api/graphql"),
        ("https://git.applifting.cz/some/path", "https://git.applifting.cz/api/v4", "https://git.applifting.cz/api/graphql"),
        ("http://gitlab.local:8929", "http://gitlab.local:8929/api/v4", "http://gitlab.local:8929/api/graphql"),
    ])
    func endpoints(base: String, rest: String, graphQL: String) throws {
        let endpoints = GitLabEndpoints(baseURL: try #require(URL(string: base)))
        #expect(endpoints.rest.absoluteString == rest)
        #expect(endpoints.graphQL.absoluteString == graphQL)
    }

    @Test("relative avatar paths resolve against the instance, absolute ones stay")
    func avatars() {
        let endpoints = GitLabEndpoints(baseURL: selfHosted)
        #expect(endpoints.resolve(avatar: "/uploads/-/system/user/avatar/1/avatar.png")?.absoluteString == "https://git.applifting.cz/uploads/-/system/user/avatar/1/avatar.png")
        #expect(endpoints.resolve(avatar: "https://secure.gravatar.com/avatar/abc?s=80")?.absoluteString == "https://secure.gravatar.com/avatar/abc?s=80")
        #expect(endpoints.resolve(avatar: nil) == nil)
        #expect(endpoints.resolve(avatar: "") == nil)
    }
}

@Suite("GitLabProvider capabilities")
struct GitLabCapabilitiesTests {
    @Test func capabilities() {
        let provider = GitLabProvider()
        #expect(provider.kind == .gitlab)
        #expect(provider.capabilities.pullRequestTerm == "Merge request")
        #expect(provider.capabilities.pullRequestAbbreviation == "MR")
        #expect(!provider.capabilities.supportsOrganizationSources)
        #expect(provider.capabilities.supportsGroupSources)
    }
}

@Suite("REST: verify and discovery")
struct GitLabRESTTests {
    @Test("verify sends PRIVATE-TOKEN and maps /user")
    func verify() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_user.json"))])
        let me = try await GitLabProvider(transport: transport).verify(baseURL: selfHosted, token: "glpat-x")

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://git.applifting.cz/api/v4/user")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-x")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Gitwall")
        #expect(me.login == "prokopsimek")
        #expect(me.displayName == "Prokop Simek")
        #expect(me.avatarURL?.absoluteString == "https://git.applifting.cz/uploads/-/system/user/avatar/12/avatar.png")
    }

    @Test("discoverRepositories lists member projects, follows pagination and filters locally")
    func discoverRepositories() async throws {
        let next = "https://git.applifting.cz/api/v4/projects?membership=true&page=2&per_page=100"
        let transport = StubTransport([
            .json(try Fixtures.data("rest_projects_page1.json"), headers: ["Link": "<\(next)>; rel=\"next\"", "X-Next-Page": "2"]),
            .json(#"[{"id":9,"path_with_namespace":"applifting/gitwall-docs","description":null,"visibility":"private","last_activity_at":"2026-01-01T00:00:00.000Z"}]"#),
        ])
        let provider = GitLabProvider(transport: transport)
        let repos = try await provider.discoverRepositories(baseURL: selfHosted, token: "t", query: nil)

        let first = try #require(await transport.requestURLs.first)
        let components = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/v4/projects")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["membership"] == "true")
        #expect(items["per_page"] == "100")
        #expect(items["order_by"] == "last_activity_at")
        #expect(items["archived"] == "false")
        #expect(await transport.requestURLs.last?.absoluteString == next)
        #expect(repos.count == 3)
        #expect(repos.first?.fullName == "gitlab-org/ci-cd/docker-machine")
        #expect(repos.first?.isPrivate == false)
        #expect(repos.last?.fullName == "applifting/gitwall-docs")
        #expect(repos.last?.isPrivate == true)

        let filtered = try await GitLabProvider(transport: StubTransport([.json(try Fixtures.data("rest_projects_page1.json"))]))
            .discoverRepositories(baseURL: selfHosted, token: "t", query: "DOCKER")
        #expect(filtered.map(\.fullName) == ["gitlab-org/ci-cd/docker-machine"])
    }

    @Test("discoverContainers lists groups as group sources including subgroups")
    func discoverGroups() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_groups.json"))])
        let groups = try await GitLabProvider(transport: transport).discoverContainers(baseURL: selfHosted, token: "t")

        let url = try #require(await transport.requestURLs.first)
        #expect(url.path == "/api/v4/groups")
        #expect(url.query?.contains("min_access_level=10") == true)
        #expect(groups.map(\.id) == ["applifting", "applifting/dx-heroes"])
        #expect(groups[0].name == "Applifting")
        #expect(groups[1].name == "Applifting / DX Heroes")
        #expect(groups[0].source == .group(fullPath: "applifting", includeSubgroups: true))
        #expect(groups[0].avatarURL?.absoluteString == "https://git.applifting.cz/uploads/-/system/group/avatar/10/logo.png")
        #expect(groups[1].avatarURL == nil)
    }
}

@Suite("Error mapping")
struct GitLabErrorTests {
    private func verifyError(_ response: StubTransport.Response) async throws -> ProviderError {
        do {
            _ = try await GitLabProvider(transport: StubTransport([response])).verify(baseURL: selfHosted, token: "t")
        } catch let error as ProviderError {
            return error
        }
        Issue.record("Expected a ProviderError")
        throw ProviderError.invalidResponse("unreachable")
    }

    @Test("401 and 403 mean the token is unusable")
    func unauthorized() async throws {
        #expect(try await verifyError(.json(try Fixtures.data("rest_error_401.json"), status: 401)) == .unauthorized)
        #expect(try await verifyError(.json(#"{"error":"insufficient_scope"}"#, status: 403)) == .unauthorized)
    }

    @Test("429 maps to rateLimited with RateLimit-Reset or Retry-After")
    func rateLimited() async throws {
        let error = try await verifyError(.json("{}", status: 429, headers: ["RateLimit-Reset": "1789021534"]))
        #expect(error == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_789_021_534)))
        let before = Date()
        let retry = try await verifyError(.json("{}", status: 429, headers: ["Retry-After": "30"]))
        guard case .rateLimited(let resetAt?) = retry else { Issue.record("expected rateLimited"); return }
        #expect(resetAt.timeIntervalSince(before) >= 29 && resetAt.timeIntervalSince(before) <= 31)
    }

    @Test("other statuses carry GitLab's message")
    func server() async throws {
        #expect(try await verifyError(.json(#"{"message":"404 Project Not Found"}"#, status: 404)) == .server(status: 404, message: "404 Project Not Found"))
        let bad = try await verifyError(.json("<html>", status: 502))
        guard case .server(let status, _) = bad else { Issue.record("expected server"); return }
        #expect(status == 502)
    }

    @Test("undecodable success body → invalidResponse")
    func invalid() async throws {
        let error = try await verifyError(.json("nope"))
        guard case .invalidResponse = error else { Issue.record("expected invalidResponse"); return }
    }
}

@Suite("GraphQL fetchItems")
struct GitLabGraphQLTests {
    private let emptyProject = #"{"data":{"project":{"fullPath":"a/b","mergeRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
    /// Real fixtures report further pages; these answer the follow-up page requests.
    private var lastPages: [StubTransport.Response] { [.json(emptyProject), .json(emptyProject), .json(emptyProject)] }

    @Test("maps the captured project fixture: merge requests and issues")
    func mapsProject() async throws {
        let transport = StubTransport([.json(try Fixtures.data("graphql_project.json"))] + lastPages)
        let items = try await GitLabProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "gitlab-org/gitlab-runner")], baseURL: cloud), token: "t", kinds: [.pullRequest, .issue]
        )
        let mrs = items.filter { $0.kind == .pullRequest }
        let issues = items.filter { $0.kind == .issue }
        #expect(mrs.count == 3)
        #expect(issues.count == 3)

        let mr = try #require(mrs.first { $0.number == 7333 })
        #expect(mr.repoFullName == "gitlab-org/gitlab-runner")
        #expect(mr.title.hasPrefix("[19.3] Gate job-supplied Docker credential helpers"))
        #expect(mr.url.absoluteString == "https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/7333")
        #expect(mr.author.login == "takax")
        #expect(mr.author.displayName == "Taka Nishida")
        #expect(mr.author.avatarURL?.absoluteString == "https://gitlab.com/uploads/-/system/user/avatar/15293556/avatar.png?v=1789032924")
        #expect(mr.labels.map(\.name).contains("type::feature"))
        #expect(mr.labels.first?.colorHex == "228B22")
        #expect(mr.assignees.map(\.login) == ["takax"])
        #expect(mr.requestedReviewers.map(\.login).contains("ajwalker"))
        #expect(!mr.requestedReviewers.map(\.login).contains("rsarangadharan"))   // already approved
        #expect(mr.reviewState == .approved)
        #expect(mr.reviewers.map(\.login) == ["rsarangadharan"])
        #expect(mr.ciState == .success)
        #expect(mr.mergeState == .clean)
        let conflicting = try #require(mrs.first { $0.number == 7335 })
        #expect(conflicting.mergeState == .conflict)
        #expect(conflicting.ciState == .running)
        #expect(mr.ciState != nil)
        #expect(mr.mergeState != nil)
        #expect(mr.isDraft == false)

        let issue = try #require(issues.first { $0.number == 39806 })
        #expect(issue.repoFullName == "gitlab-org/gitlab-runner")
        #expect(issue.url.absoluteString.hasSuffix("/-/work_items/39806"))
        #expect(issue.reviewState == nil && issue.ciState == nil && issue.mergeState == nil)
        #expect(issue.labels.count > 0)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://gitlab.com/api/graphql")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t")
        #expect(try await transport.graphQLVariable("path", at: 0) == "gitlab-org/gitlab-runner")
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains("project(fullPath: $path)"))
        #expect(query.contains("mergeRequests(state: opened, first: 50"))
        #expect(query.contains("issues(state: opened, first: 50"))
        #expect(query.contains("mergeRequestInteraction"))
    }

    @Test("group sources use the group query with subgroups and derive the project from the item URL")
    func mapsGroup() async throws {
        let transport = StubTransport([.json(try Fixtures.data("graphql_group.json"))] + lastPages)
        let items = try await GitLabProvider(transport: transport).fetchItems(
            account: account([.group(fullPath: "gitlab-org/ci-cd", includeSubgroups: true)], baseURL: cloud), token: "t", kinds: [.pullRequest, .issue]
        )
        #expect(items.filter { $0.kind == .pullRequest }.count == 3)
        #expect(items.filter { $0.kind == .issue }.count == 3)
        let issue = try #require(items.first { $0.kind == .issue && $0.number == 226 })
        #expect(issue.repoFullName == "gitlab-org/ci-cd/runner-tools/grit")
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains("group(fullPath: $path)"))
        #expect(query.contains("includeSubgroups: $subgroups"))
        #expect(try await transport.graphQLVariable("path", at: 0) == "gitlab-org/ci-cd")
    }

    @Test("only requested connections are queried and one request is sent per source")
    func kindsAndRequests() async throws {
        let transport = StubTransport([.json(emptyProject), .json(emptyProject), .json(emptyProject)])
        _ = try await GitLabProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "a/b"), .repository(fullName: "c/d"), .repository(fullName: "e/f")]),
            token: "t", kinds: [.pullRequest]
        )
        #expect(await transport.requests.count == 3)
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains("mergeRequests("))
        #expect(!query.contains("issues("))
        // GitLab rejects declared-but-unused variables.
        #expect(!query.contains("$issueAfter"))
        #expect(query.contains("$mrAfter"))
    }

    @Test("query declarations match the requested connections and source type")
    func queryVariables() {
        let issuesOnly = GitLabQueries.query(for: .repository(fullName: "a/b"), kinds: [.issue], interaction: true)
        #expect(issuesOnly.contains("$issueAfter: String"))
        #expect(!issuesOnly.contains("$mrAfter"))
        #expect(!issuesOnly.contains("$subgroups"))
        let group = GitLabQueries.query(for: .group(fullPath: "g", includeSubgroups: true), kinds: [.pullRequest, .issue], interaction: false)
        #expect(group.contains("$path: ID!, $subgroups: Boolean!, $mrAfter: String, $issueAfter: String"))
        #expect(!group.contains("mergeRequestInteraction"))
    }

    @Test("follows pagination per connection up to three extra pages")
    func pagination() async throws {
        func page(_ n: Int, more: Bool) -> String {
            #"{"data":{"project":{"fullPath":"a/b","mergeRequests":{"pageInfo":{"hasNextPage":\#(more),"endCursor":"c\#(n)"},"nodes":[{"iid":"\#(n)","title":"MR \#(n)","webUrl":"https://git.applifting.cz/a/b/-/merge_requests/\#(n)","draft":false,"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","author":{"username":"x","name":null,"avatarUrl":null},"reviewers":{"nodes":[]},"approvedBy":{"nodes":[]},"labels":{"nodes":[]},"assignees":{"nodes":[]},"project":{"fullPath":"a/b"}}]}}}}"#
        }
        let transport = StubTransport([.json(page(1, more: true)), .json(page(2, more: true)), .json(page(3, more: true)), .json(page(4, more: true)), .json(page(5, more: true))])
        let items = try await GitLabProvider(transport: transport).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        #expect(items.map(\.number) == [1, 2, 3, 4])
        #expect(await transport.requests.count == 4)
        #expect(try await transport.graphQLVariable("mrAfter", at: 1) == "c1")
    }

    @Test("older instances without mergeRequestInteraction get a retry without the field")
    func reviewStateFallback() async throws {
        let mr = #"{"iid":"5","title":"MR","webUrl":"https://git.applifting.cz/a/b/-/merge_requests/5","draft":false,"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","author":{"username":"x"},"reviewers":{"nodes":[{"username":"me"},{"username":"other"}]},"approvedBy":{"nodes":[{"username":"other"}]},"approved":false,"labels":{"nodes":[]},"assignees":{"nodes":[]},"project":{"fullPath":"a/b"}}"#
        let ok = #"{"data":{"project":{"fullPath":"a/b","mergeRequests":{"pageInfo":{"hasNextPage":false},"nodes":[\#(mr)]}}}}"#
        let transport = StubTransport([.json(try Fixtures.data("graphql_error_undefined_field.json")), .json(ok), .json(ok)])
        let provider = GitLabProvider(transport: transport)
        let items = try await provider.fetchItems(account: account([.repository(fullName: "a/b")], me: "me"), token: "t", kinds: [.pullRequest])

        #expect(items.count == 1)
        #expect(items[0].requestedReviewers.map(\.login) == ["me"])   // "other" already approved
        #expect(items[0].reviewers.map(\.login) == ["other"])
        #expect(items[0].reviewState == .pending)
        #expect(await transport.requests.count == 2)
        #expect(try await transport.graphQLQuery(at: 0).contains("mergeRequestInteraction"))
        #expect(!(try await transport.graphQLQuery(at: 1).contains("mergeRequestInteraction")))

        // The capability is remembered for the instance: the next fetch goes straight to the plain query.
        _ = try await provider.fetchItems(account: account([.repository(fullName: "a/b")], me: "me"), token: "t", kinds: [.pullRequest])
        #expect(await transport.requests.count == 3)
        #expect(!(try await transport.graphQLQuery(at: 2).contains("mergeRequestInteraction")))
    }

    @Test("GraphQL errors without data map to provider errors")
    func graphQLErrors() async throws {
        let transport = StubTransport([.json(#"{"errors":[{"message":"Query has complexity of 300, which exceeds max complexity of 250"}]}"#)])
        await #expect(throws: ProviderError.self) {
            _ = try await GitLabProvider(transport: transport).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        }
    }

    @Test("a project that cannot be found is skipped")
    func missingProject() async throws {
        let transport = StubTransport([.json(#"{"data":{"project":null}}"#)])
        let items = try await GitLabProvider(transport: transport).fetchItems(account: account([.repository(fullName: "a/missing")]), token: "t", kinds: [.pullRequest])
        #expect(items.isEmpty)
    }
}

@Suite("GraphQL mapping")
struct GitLabMappingTests {
    @Test("review state: approved wins, requested changes next, reviewers pending, otherwise none")
    func reviewState() {
        #expect(GitLabMapping.reviewState(approved: true, reviewerStates: ["REQUESTED_CHANGES"], reviewerCount: 1) == .approved)
        #expect(GitLabMapping.reviewState(approved: false, reviewerStates: ["UNREVIEWED", "REQUESTED_CHANGES"], reviewerCount: 2) == .changesRequested)
        #expect(GitLabMapping.reviewState(approved: false, reviewerStates: ["UNREVIEWED"], reviewerCount: 1) == .pending)
        #expect(GitLabMapping.reviewState(approved: false, reviewerStates: [], reviewerCount: 2) == .pending)
        #expect(GitLabMapping.reviewState(approved: false, reviewerStates: [], reviewerCount: 0) == ReviewState.none)
    }

    @Test("pipeline statuses")
    func ci() {
        #expect(GitLabMapping.ciState("SUCCESS") == .success)
        #expect(GitLabMapping.ciState("FAILED") == .failure)
        for running in ["RUNNING", "PENDING", "CREATED", "PREPARING", "WAITING_FOR_RESOURCE", "SCHEDULED"] {
            #expect(GitLabMapping.ciState(running) == .running, "\(running)")
        }
        for none in ["CANCELED", "SKIPPED", "MANUAL", nil] {
            #expect(GitLabMapping.ciState(none) == CIState.none, "\(none ?? "nil")")
        }
    }

    @Test("merge state from conflicts flag and detailed status")
    func merge() {
        #expect(GitLabMapping.mergeState(conflicts: true, detailed: "MERGEABLE") == .conflict)
        #expect(GitLabMapping.mergeState(conflicts: false, detailed: "MERGEABLE") == .clean)
        #expect(GitLabMapping.mergeState(conflicts: false, detailed: "CONFLICT") == .conflict)
        #expect(GitLabMapping.mergeState(conflicts: false, detailed: "CI_MUST_PASS") == .unknown)
        #expect(GitLabMapping.mergeState(conflicts: nil, detailed: nil) == .unknown)
    }

    @Test("project path is derived from item URLs")
    func projectPath() {
        let base = URL(string: "https://gitlab.com")!
        #expect(GitLabMapping.projectPath(from: URL(string: "https://gitlab.com/gitlab-org/ci-cd/runner-tools/grit/-/work_items/226")!, baseURL: base) == "gitlab-org/ci-cd/runner-tools/grit")
        #expect(GitLabMapping.projectPath(from: URL(string: "https://gitlab.com/a/b/-/merge_requests/1")!, baseURL: base) == "a/b")
        #expect(GitLabMapping.projectPath(from: URL(string: "https://elsewhere.example/a/b/-/issues/1")!, baseURL: base) == "a/b")
    }
}

@Suite("Integration", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITLAB_TOKEN"] != nil))
struct GitLabIntegrationTests {
    private var token: String { ProcessInfo.processInfo.environment["GITWALL_GITLAB_TOKEN"] ?? "" }
    private var baseURL: URL { URL(string: ProcessInfo.processInfo.environment["GITWALL_GITLAB_URL"] ?? "https://gitlab.com")! }

    @Test("verify, discover and fetch against a real instance")
    func endToEnd() async throws {
        let provider = GitLabProvider()
        let me = try await provider.verify(baseURL: baseURL, token: token)
        #expect(!me.login.isEmpty)
        let repos = try await provider.discoverRepositories(baseURL: baseURL, token: token, query: nil)
        let groups = try await provider.discoverContainers(baseURL: baseURL, token: token)
        print("integration: \(repos.count) projects, \(groups.count) groups as \(me.login)")
        #expect(!repos.isEmpty)
        let sources: [RepoSource] = Array(repos.prefix(3)).map { .repository(fullName: $0.fullName) }
        let items = try await provider.fetchItems(account: Account(kind: .gitlab, baseURL: baseURL, displayName: "GitLab", me: me, sources: sources), token: token, kinds: [.pullRequest, .issue])
        print("integration: \(items.count) items from \(sources.count) projects")
        let onlyMRs = try await provider.fetchItems(account: Account(kind: .gitlab, baseURL: baseURL, displayName: "GitLab", me: me, sources: sources), token: token, kinds: [.pullRequest])
        #expect(onlyMRs.allSatisfy { $0.kind == .pullRequest })
        if let group = groups.first {
            let grouped = try await provider.fetchItems(account: Account(kind: .gitlab, baseURL: baseURL, displayName: "GitLab", me: me, sources: [group.source]), token: token, kinds: [.issue])
            print("integration: \(grouped.count) issues from group \(group.id)")
        }
    }
}
