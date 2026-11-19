import Foundation
import GitwallCore
import OSLog

/// `GitProvider` for GitHub.com and GitHub Enterprise Server.
/// REST for identity and discovery, GraphQL for pull requests and issues.
public struct GitHubProvider: GitProvider {
    public let kind: ProviderKind = .github
    public let capabilities = ProviderCapabilities(
        pullRequestTerm: "Pull request",
        pullRequestAbbreviation: "PR",
        supportsOrganizationSources: true,
        supportsGroupSources: false,
        resolvesTeamReviewRequests: true,
        hostName: "GitHub",
        fetchesItemDetail: true
    )

    static let maxRepositoryPages = 5

    let client: GitHubClient
    /// Shared by every copy of this provider, so searches and item-state lookups of one sync ask GitHub for the viewer's
    /// teams once per account.
    let teamCache: TeamSlugCache

    public init(transport: any HTTPTransport = URLSessionTransport(), userAgent: String = "Gitwall") {
        client = GitHubClient(transport: transport, userAgent: userAgent)
        teamCache = TeamSlugCache()
    }

    /// For tests: `sleep` stands in for the wait before a 502, 503 or 504 is tried again.
    init(
        transport: any HTTPTransport, userAgent: String = "Gitwall", sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        client = GitHubClient(transport: transport, userAgent: userAgent, sleep: sleep)
        teamCache = TeamSlugCache(now: now)
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
        // Resolved lazily: only a batch that actually contains a review request for a team pays for the query.
        let teams = TeamSlugs()

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
            items += try await fetchRepositoryBatch(slice, kinds: kinds, account: account, token: token, endpoints: endpoints, teams: teams)
        }
        for organization in organizations {
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                items += try await fetchSearch(organization: organization, kind: kind, account: account, token: token, endpoints: endpoints, teams: teams)
            }
        }

        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    /// One lookup per fetch, shared by every batch and page; the provider's ``TeamSlugCache`` is asked at most once
    /// through it.
    actor TeamSlugs {
        private var slugs: Set<String>?

        func resolve(_ load: () async -> Set<String>) async -> Set<String> {
            if let slugs { return slugs }
            let loaded = await load()
            slugs = loaded
            return loaded
        }
    }

    /// Nothing to resolve unless the token owner is known and GitHub asked one of their teams for a review.
    func teamSlugs(
        for nodes: [ItemNode],
        account: Account,
        token: String,
        endpoints: GitHubEndpoints,
        teams: TeamSlugs
    ) async -> Set<String> {
        guard account.me != nil else { return [] }
        let asksATeam = nodes.contains { node in
            node.reviewRequests?.items.contains { $0.requestedReviewer?.__typename == "Team" } ?? false
        }
        guard asksATeam else { return [] }
        let key = TeamSlugCache.Key(accountID: account.id, token: token)
        return await teams.resolve {
            await teamCache.slugs(for: key) { await viewerTeamSlugs(endpoints: endpoints, token: token) }
        }
    }

    /// Teams the token owner belongs to, as `owner/slug`. Empty when the token may not read them, which leaves
    /// team review requests out of the queue exactly as before; only an answer without errors is worth keeping.
    private func viewerTeamSlugs(endpoints: GitHubEndpoints, token: String) async -> TeamLookup {
        do {
            let response = try await client.graphQL(ViewerTeamsData.self, endpoint: endpoints.graphQL, token: token,
                                                    query: GraphQLQueries.viewerTeams)
            let slugs = response.data?.slugs ?? []
            if let errors = response.errors, !errors.isEmpty {
                gitHubLog.info("\(TeamLookupLog.unresolved(errors), privacy: .public)")
                return .unreliable(slugs)
            }
            return .resolved(slugs)
        } catch {
            gitHubLog.info("\(TeamLookupLog.failed(error), privacy: .public)")
            return .unreliable([])
        }
    }

    private func fetchRepositoryBatch(
        _ repositories: [(owner: String, name: String)],
        kinds: Set<ItemKind>,
        account: Account,
        token: String,
        endpoints: GitHubEndpoints,
        teams: TeamSlugs
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
            if node.isArchived == true {
                gitHubLog.info("Repository \(fullName, privacy: .public) is archived; skipping its items")
                continue
            }
            items += try await collect(node: node, kinds: kinds, repo: repo, account: account, token: token, endpoints: endpoints, teams: teams)
        }
        return items
    }

    private func collect(
        node: RepositoryNode,
        kinds: Set<ItemKind>,
        repo: (owner: String, name: String),
        account: Account,
        token: String,
        endpoints: GitHubEndpoints,
        teams: TeamSlugs
    ) async throws -> [WorkItem] {
        var items: [WorkItem] = []
        for kind in kinds {
            var connection = kind == .pullRequest ? node.pullRequests : node.issues
            var pages = 0
            while let current = connection {
                let slugs = await teamSlugs(for: current.items, account: account, token: token, endpoints: endpoints, teams: teams)
                items += current.items.map { GraphQLMapping.workItem($0, kind: kind, accountID: account.id, fallbackRepository: node.nameWithOwner,
                                                                     viewer: account.me, teamSlugs: slugs) }
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

    private func fetchSearch(organization: String, kind: ItemKind, account: Account, token: String, endpoints: GitHubEndpoints,
                             teams: TeamSlugs) async throws -> [WorkItem] {
        let q = try GraphQLQueries.searchQuery(organization: organization, kind: kind, nativeQuery: account.nativeQuery)
        var items: [WorkItem] = []
        var after: String?
        for _ in 0..<GraphQLQueries.maxSearchPages {
            let response = try await client.graphQL(SearchData.self, endpoint: endpoints.graphQL, token: token, query: GraphQLQueries.search, variables: ["q": q, "after": after])
            guard let search = response.data?.search else { break }
            let matching = search.items.filter { ($0.__typename == "PullRequest") == (kind == .pullRequest) }
            let slugs = await teamSlugs(for: matching, account: account, token: token, endpoints: endpoints, teams: teams)
            items += matching.map { GraphQLMapping.workItem($0, kind: kind, accountID: account.id, fallbackRepository: organization,
                                                            viewer: account.me, teamSlugs: slugs) }
            guard let pageInfo = search.pageInfo, pageInfo.hasNextPage, let cursor = pageInfo.endCursor else { break }
            after = cursor
        }
        return items
    }
}

// MARK: - Project priorities

extension GitHubProvider {
    /// Reads the Priority field of every item's open projects in batches of 100 node ids, after the lists. A token
    /// without `read:project` (classic, OAuth) or Projects: Read (fine-grained) yields `.missingPermission`, never an
    /// error: the items keep their label priority and the sync stays green. See `docs/adr/0012`.
    public func projectPriorities(account: Account, token: String, items: [WorkItem]) async -> PriorityLookup {
        var itemIDs: [String: String] = [:]
        for item in items {
            guard let nodeID = item.nodeID, GraphQLQueries.isNodeID(nodeID) else { continue }
            itemIDs[nodeID] = item.id
        }
        // Nothing to ask about; the last lookup's state stands.
        guard !itemIDs.isEmpty else { return .failed("No items to look up") }

        let endpoints = GitHubEndpoints(baseURL: account.baseURL)
        let nodeIDs = itemIDs.keys.sorted()
        var priorities: [String: Priority] = [:]
        var refused = false
        for start in stride(from: 0, to: nodeIDs.count, by: GraphQLQueries.maxPriorityLookupsPerRequest) {
            let batch = Array(nodeIDs[start..<min(start + GraphQLQueries.maxPriorityLookupsPerRequest, nodeIDs.count)])
            do {
                let response = try await client.graphQL(PriorityNodesData.self, endpoint: endpoints.graphQL, token: token,
                                                        query: GraphQLQueries.projectPriorities(nodeIDs: batch))
                // A field GitHub refuses on its own comes back as a partial answer with an error beside it.
                refused = refused || (response.errors ?? []).contains { Self.refusesProjects($0) }
                for node in response.data?.nodes ?? [] {
                    guard let node, let id = node.id, let itemID = itemIDs[id], let priority = node.priority else { continue }
                    priorities[itemID] = priority
                }
            } catch ProviderError.unauthorized {
                // `INSUFFICIENT_SCOPES` or `FORBIDDEN` without data. The lists were just read with this token, so it
                // is the projects the token may not read, not the token itself.
                gitHubLog.info("Project priorities skipped for \(account.displayName, privacy: .public): the token may not read projects")
                return .missingPermission
            } catch {
                gitHubLog.info("Project priorities unavailable: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
        if refused, priorities.isEmpty {
            gitHubLog.info("Project priorities refused for \(account.displayName, privacy: .public)")
            return .missingPermission
        }
        return .found(priorities)
    }

    private static func refusesProjects(_ error: GraphQLError) -> Bool {
        switch error.type?.uppercased() {
        case "FORBIDDEN", "INSUFFICIENT_SCOPES": true
        default: false
        }
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

// MARK: - Team lookup

/// What one look at the viewer's teams came to.
enum TeamLookup: Sendable {
    /// GitHub answered without errors; worth keeping for a while.
    case resolved(Set<String>)
    /// The request failed or came with errors; used for this fetch only, so the next one asks again.
    case unreliable(Set<String>)
}

/// The viewer's teams per account and token, kept for ``lifetime``. Only a clean answer is kept, so a refusal that
/// may pass is asked again by the next fetch. The token is only a key in memory and is never logged.
actor TeamSlugCache {
    struct Key: Hashable, Sendable {
        let accountID: UUID
        let token: String
    }

    static let lifetime: TimeInterval = 5 * 60

    private var entries: [Key: (slugs: Set<String>, loadedAt: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func slugs(for key: Key, load: () async -> TeamLookup) async -> Set<String> {
        if let entry = entries[key], now().timeIntervalSince(entry.loadedAt) < Self.lifetime {
            return entry.slugs
        }
        switch await load() {
        case .resolved(let slugs):
            entries[key] = (slugs, now())
            return slugs
        case .unreliable(let slugs):
            entries[key] = nil
            return slugs
        }
    }
}

/// What the unified log says about the team lookup: counts and types, never GitHub's text, which can name an
/// organization.
enum TeamLookupLog {
    static func unresolved(_ errors: [GraphQLError]) -> String {
        "Team review requests stay unresolved: \(errors.typeSummary)"
    }

    static func failed(_ error: Error) -> String {
        "Could not read the viewer's teams: \(String(describing: type(of: error)))"
    }
}
