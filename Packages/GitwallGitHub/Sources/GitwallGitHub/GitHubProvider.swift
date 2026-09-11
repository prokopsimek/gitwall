import Foundation
import GitwallCore

/// `GitProvider` for GitHub.com and GitHub Enterprise Server.
/// REST for identity and discovery, GraphQL for pull requests and issues.
public struct GitHubProvider: GitProvider {
    public let kind: ProviderKind = .github
    public let capabilities = ProviderCapabilities(
        pullRequestTerm: "Pull request",
        pullRequestAbbreviation: "PR",
        supportsOrganizationSources: true,
        supportsGroupSources: false,
        resolvesTeamReviewRequests: false
    )

    static let maxRepositoryPages = 5

    let client: GitHubClient

    public init(transport: any HTTPTransport = URLSessionTransport(), userAgent: String = "Gitwall") {
        client = GitHubClient(transport: transport, userAgent: userAgent)
    }

    // MARK: REST

    public func verify(baseURL: URL, token: String) async throws -> UserRef {
        let endpoints = GitHubEndpoints(baseURL: baseURL)
        let (user, _) = try await client.get(RESTUser.self, url: endpoints.rest.appendingPathComponent("user"), token: token)
        return UserRef(login: user.login, displayName: user.name, avatarURL: user.avatar_url)
    }

    /// Fine-grained and expiring classic tokens carry `GitHub-Authentication-Token-Expiration` on every response.
    public func tokenExpiry(baseURL: URL, token: String) async -> Date? {
        let endpoints = GitHubEndpoints(baseURL: baseURL)
        guard let (_, response) = try? await client.get(RESTUser.self, url: endpoints.rest.appendingPathComponent("user"), token: token) else {
            return nil
        }
        return TokenExpiryHeader.date(from: response)
    }

    public func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] {
        let endpoints = GitHubEndpoints(baseURL: baseURL)
        var components = URLComponents(url: endpoints.rest.appendingPathComponent("user/repos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ]
        let repos = try await client.getAllPages(RESTRepository.self, url: components.url!, token: token, maxPages: Self.maxRepositoryPages)
        var refs = repos.map {
            RepoRef(fullName: $0.full_name, description: $0.description, isPrivate: $0.private ?? false,
                    isArchived: $0.archived ?? false, updatedAt: $0.pushed_at)
        }
        refs.sort { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.fullName < rhs.fullName
            }
        }
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !needle.isEmpty else { return refs }
        return refs.filter { $0.fullName.lowercased().contains(needle) }
    }

    public func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] {
        let endpoints = GitHubEndpoints(baseURL: baseURL)
        var components = URLComponents(url: endpoints.rest.appendingPathComponent("user/orgs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        let orgs = try await client.getAllPages(RESTOrganization.self, url: components.url!, token: token, maxPages: Self.maxRepositoryPages)
        return orgs.map {
            ContainerRef(id: $0.login, name: $0.login, source: .organization(login: $0.login), avatarURL: $0.avatar_url)
        }
    }

    // MARK: GraphQL

    public func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] {
        guard !kinds.isEmpty else { return [] }
        let endpoints = GitHubEndpoints(baseURL: account.baseURL)
        var items: [WorkItem] = []

        var repositories: [(owner: String, name: String)] = []
        var organizations: [String] = []
        for source in account.sources {
            switch source {
            case .repository(let fullName):
                if let split = GraphQLQueries.splitFullName(fullName) {
                    repositories.append(split)
                } else {
                    gitHubLog.error("Skipping invalid repository name \(fullName, privacy: .public)")
                }
            case .organization(let login):
                organizations.append(login)
            case .group:
                continue
            }
        }

        for batch in stride(from: 0, to: repositories.count, by: GraphQLQueries.maxRepositoriesPerBatch) {
            let slice = Array(repositories[batch..<min(batch + GraphQLQueries.maxRepositoriesPerBatch, repositories.count)])
            items += try await fetchRepositoryBatch(slice, kinds: kinds, account: account, token: token, endpoints: endpoints)
        }
        for organization in organizations {
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                items += try await fetchSearch(organization: organization, kind: kind, account: account, token: token, endpoints: endpoints)
            }
        }

        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    private func fetchRepositoryBatch(
        _ repositories: [(owner: String, name: String)],
        kinds: Set<ItemKind>,
        account: Account,
        token: String,
        endpoints: GitHubEndpoints
    ) async throws -> [WorkItem] {
        let query = GraphQLQueries.repositoryBatch(repositories, kinds: kinds)
        let response = try await client.graphQL(RepositoryBatchData.self, endpoint: endpoints.graphQL, token: token, query: query)
        guard let data = response.data else { return [] }

        for error in response.errors ?? [] where error.type?.uppercased() != "NOT_FOUND" {
            gitHubLog.error("GraphQL warning: \(error.message, privacy: .public)")
        }

        var items: [WorkItem] = []
        for (index, repo) in repositories.enumerated() {
            let fullName = "\(repo.owner)/\(repo.name)"
            guard let node = data.repositories["r\(index)"] ?? nil else {
                gitHubLog.error("Repository \(fullName, privacy: .public) not found or not accessible; skipping")
                continue
            }
            items += try await collect(node: node, kinds: kinds, repo: repo, account: account, token: token, endpoints: endpoints)
        }
        return items
    }

    private func collect(
        node: RepositoryNode,
        kinds: Set<ItemKind>,
        repo: (owner: String, name: String),
        account: Account,
        token: String,
        endpoints: GitHubEndpoints
    ) async throws -> [WorkItem] {
        var items: [WorkItem] = []
        for kind in kinds {
            var connection = kind == .pullRequest ? node.pullRequests : node.issues
            var pages = 0
            while let current = connection {
                items += current.items.map { GraphQLMapping.workItem($0, kind: kind, accountID: account.id, fallbackRepository: node.nameWithOwner) }
                guard let pageInfo = current.pageInfo, pageInfo.hasNextPage, let cursor = pageInfo.endCursor,
                      pages < GraphQLQueries.maxExtraPagesPerRepository else { break }
                pages += 1
                let query = GraphQLQueries.repositoryPage(owner: repo.owner, name: repo.name, kind: kind, after: cursor)
                let response = try await client.graphQL(RepositoryBatchData.self, endpoint: endpoints.graphQL, token: token, query: query)
                let next = response.data?.repositories["r0"] ?? nil
                connection = kind == .pullRequest ? next?.pullRequests : next?.issues
            }
        }
        return items
    }

    private func fetchSearch(organization: String, kind: ItemKind, account: Account, token: String, endpoints: GitHubEndpoints) async throws -> [WorkItem] {
        let q = try GraphQLQueries.searchQuery(organization: organization, kind: kind, nativeQuery: account.nativeQuery)
        var items: [WorkItem] = []
        var after: String?
        for _ in 0..<GraphQLQueries.maxSearchPages {
            let response = try await client.graphQL(SearchData.self, endpoint: endpoints.graphQL, token: token, query: GraphQLQueries.search, variables: ["q": q, "after": after])
            guard let search = response.data?.search else { break }
            items += search.items
                .filter { ($0.__typename == "PullRequest") == (kind == .pullRequest) }
                .map { GraphQLMapping.workItem($0, kind: kind, accountID: account.id, fallbackRepository: organization) }
            guard let pageInfo = search.pageInfo, pageInfo.hasNextPage, let cursor = pageInfo.endCursor else { break }
            after = cursor
        }
        return items
    }
}

// MARK: - REST models

private struct RESTUser: Decodable {
    let login: String
    let name: String?
    let avatar_url: URL?
}

private struct RESTRepository: Decodable {
    let full_name: String
    let description: String?
    let `private`: Bool?
    let archived: Bool?
    let pushed_at: Date?
}

private struct RESTOrganization: Decodable {
    let login: String
    let avatar_url: URL?
}
