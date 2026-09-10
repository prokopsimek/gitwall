import Foundation
import GitwallCore

/// Remembers per instance whether the GraphQL schema knows `mergeRequestInteraction` (GitLab ≥ 16).
actor GitLabSchemaCache {
    private var interactionUnsupported: Set<String> = []

    func supportsInteraction(host: String) -> Bool { !interactionUnsupported.contains(host) }
    func markInteractionUnsupported(host: String) { interactionUnsupported.insert(host) }
}

/// `GitProvider` for gitlab.com and self-managed GitLab.
/// REST for identity and discovery, GraphQL for merge requests and issues.
public struct GitLabProvider: GitProvider {
    public let kind: ProviderKind = .gitlab
    public let capabilities = ProviderCapabilities(
        pullRequestTerm: "Merge request",
        pullRequestAbbreviation: "MR",
        supportsOrganizationSources: false,
        supportsGroupSources: true,
        resolvesTeamReviewRequests: false
    )

    static let maxDiscoveryPages = 5
    static let maxConcurrentSources = 4

    let client: GitLabClient
    private let schema = GitLabSchemaCache()

    public init(transport: any HTTPTransport = URLSessionTransport(), userAgent: String = "Gitwall") {
        client = GitLabClient(transport: transport, userAgent: userAgent)
    }

    // MARK: REST

    public func verify(baseURL: URL, token: String) async throws -> UserRef {
        let endpoints = GitLabEndpoints(baseURL: baseURL)
        let (user, _) = try await client.get(RESTUser.self, url: endpoints.rest.appendingPathComponent("user"), token: token)
        return UserRef(login: user.username, displayName: user.name, avatarURL: endpoints.resolve(avatar: user.avatar_url))
    }

    public func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] {
        let endpoints = GitLabEndpoints(baseURL: baseURL)
        var components = URLComponents(url: endpoints.rest.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "membership", value: "true"),
            URLQueryItem(name: "archived", value: "false"),
            URLQueryItem(name: "simple", value: "true"),
            URLQueryItem(name: "order_by", value: "last_activity_at"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        let projects = try await client.getAllPages(RESTProject.self, url: components.url!, token: token, maxPages: Self.maxDiscoveryPages)
        var refs = projects.map {
            RepoRef(fullName: $0.path_with_namespace, description: $0.description, isPrivate: $0.visibility != "public",
                    isArchived: $0.archived ?? false, updatedAt: $0.last_activity_at)
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
        let endpoints = GitLabEndpoints(baseURL: baseURL)
        var components = URLComponents(url: endpoints.rest.appendingPathComponent("groups"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "min_access_level", value: "10"),
            URLQueryItem(name: "order_by", value: "name"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        let groups = try await client.getAllPages(RESTGroup.self, url: components.url!, token: token, maxPages: Self.maxDiscoveryPages)
        return groups.map {
            ContainerRef(id: $0.full_path, name: $0.full_name ?? $0.full_path,
                         source: .group(fullPath: $0.full_path, includeSubgroups: true),
                         avatarURL: endpoints.resolve(avatar: $0.avatar_url))
        }
    }

    // MARK: GraphQL

    public func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] {
        guard !kinds.isEmpty else { return [] }
        let endpoints = GitLabEndpoints(baseURL: account.baseURL)
        let sources = account.sources.filter { source in
            if case .organization = source { return false }
            return true
        }
        var items: [WorkItem] = []
        // Limited parallelism: a few sources at a time keeps us well inside GitLab's rate limits.
        for chunk in stride(from: 0, to: sources.count, by: Self.maxConcurrentSources) {
            let slice = Array(sources[chunk..<min(chunk + Self.maxConcurrentSources, sources.count)])
            let fetched = try await withThrowingTaskGroup(of: [WorkItem].self, returning: [[WorkItem]].self) { group in
                for source in slice {
                    group.addTask { try await self.fetch(source: source, kinds: kinds, account: account, token: token, endpoints: endpoints) }
                }
                var collected: [[WorkItem]] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            items += fetched.flatMap { $0 }
        }
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    private func fetch(source: RepoSource, kinds: Set<ItemKind>, account: Account, token: String, endpoints: GitLabEndpoints) async throws -> [WorkItem] {
        let path: String
        var variables: [String: Any?] = [:]
        switch source {
        case .repository(let fullName):
            path = fullName
        case .group(let fullPath, let includeSubgroups):
            path = fullPath
            variables["subgroups"] = includeSubgroups
        case .organization:
            return []
        }
        variables["path"] = path

        var items: [WorkItem] = []
        var wanted = kinds
        var mrAfter: String?
        var issueAfter: String?
        var pages = 0
        while !wanted.isEmpty, pages <= GitLabQueries.maxExtraPages {
            pages += 1
            var vars = variables
            if wanted.contains(.pullRequest) { vars["mrAfter"] = mrAfter }
            if wanted.contains(.issue) { vars["issueAfter"] = issueAfter }
            let data = try await run(source: source, kinds: wanted, variables: vars, token: token, endpoints: endpoints)
            guard let node = data.container else {
                gitLabLog.error("GitLab could not resolve \(path, privacy: .public); skipping")
                return []
            }
            if wanted.contains(.pullRequest) {
                let connection = node.mergeRequests
                items += connection?.items.map { GitLabMapping.workItem($0, accountID: account.id, endpoints: endpoints) } ?? []
                if let info = connection?.pageInfo, info.hasNextPage, let cursor = info.endCursor {
                    mrAfter = cursor
                } else {
                    wanted.remove(.pullRequest)
                }
            }
            if wanted.contains(.issue) {
                let connection = node.issues
                items += connection?.items.map { GitLabMapping.workItem($0, accountID: account.id, endpoints: endpoints) } ?? []
                if let info = connection?.pageInfo, info.hasNextPage, let cursor = info.endCursor {
                    issueAfter = cursor
                } else {
                    wanted.remove(.issue)
                }
            }
        }
        return items
    }

    /// Runs one query, retrying without `mergeRequestInteraction` when the instance's schema lacks it.
    private func run(source: RepoSource, kinds: Set<ItemKind>, variables: [String: Any?], token: String, endpoints: GitLabEndpoints) async throws -> ContainerData {
        let host = endpoints.baseURL.host ?? endpoints.baseURL.absoluteString
        let interaction = await schema.supportsInteraction(host: host)
        let query = GitLabQueries.query(for: source, kinds: kinds, interaction: interaction)
        do {
            let response = try await client.graphQL(ContainerData.self, endpoint: endpoints.graphQL, token: token, query: query, variables: variables)
            if let complexity = response.data?.complexity {
                gitLabLog.debug("GraphQL complexity \(complexity.score)/\(complexity.limit)")
            }
            guard let data = response.data else { throw ProviderError.invalidResponse("GraphQL response without data") }
            return data
        } catch let error as ProviderError {
            if interaction, case .server(_, let message) = error, message.contains("mergeRequestInteraction") {
                gitLabLog.info("Instance \(host, privacy: .public) has no mergeRequestInteraction; retrying without it")
                await schema.markInteractionUnsupported(host: host)
                return try await run(source: source, kinds: kinds, variables: variables, token: token, endpoints: endpoints)
            }
            throw error
        }
    }
}

// MARK: - REST models

private struct RESTUser: Decodable {
    let username: String
    let name: String?
    let avatar_url: String?
}

private struct RESTProject: Decodable {
    let path_with_namespace: String
    let description: String?
    let visibility: String?
    let archived: Bool?
    let last_activity_at: Date?
}

private struct RESTGroup: Decodable {
    let full_path: String
    let full_name: String?
    let avatar_url: String?
}
