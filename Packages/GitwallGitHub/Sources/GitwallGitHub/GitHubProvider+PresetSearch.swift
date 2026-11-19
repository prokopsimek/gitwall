import Foundation
import GitwallCore

// MARK: - Preset search

extension GitHubProvider {
    /// GitHub.com searches per preset. GitHub Enterprise Server keeps ``fetchItems(account:token:kinds:)``: its search is
    /// older and its instances differ in what they accept.
    public func capabilities(for account: Account) -> ProviderCapabilities {
        var capabilities = self.capabilities
        capabilities.presetSearch = account.isCloudInstance
        return capabilities
    }

    /// One `ISSUE_ADVANCED` search per kind of the preset, over the scope's repositories or else every organization and
    /// repository of the account, written by ``PresetSearchQuery``. A search too long for GitHub is split by its sources
    /// or, where even one source does not fit, widened by leaving out filter terms. Each search is paged up to
    /// ``GraphQLQueries/maxPresetSearchResults``, and only items from its own sources are kept, because GitHub drops a
    /// source it does not know without a word and then searches all of GitHub.
    ///
    /// Errors are those of every request: a refused token is `.unauthorized`, a rate limit `.rateLimited`, GraphQL
    /// errors in a 200 answer `.server(status: 200, …)`, a rejected request `.server(status:…)` with its status.
    public func fetchPresetItems(account: Account, token: String, search: PresetSearch) async throws -> PresetFetch {
        guard capabilities(for: account).presetSearch else { throw ProviderError.unsupported("Preset search") }
        let sources = Self.presetSources(account: account, repositories: search.repositories)
        guard !sources.isEmpty, !search.kinds.isEmpty else {
            return PresetFetch(items: [], totalCount: 0, isComplete: true, requests: 0)
        }

        // Every request of this fetch passes the counter: repeats after a gateway error and the team lookup too.
        let counter = RequestCounter(transport: client.transport)
        let counted = GitHubProvider(client: GitHubClient(transport: counter, userAgent: client.userAgent, sleep: client.sleep))
        let found = try await counted.searchPreset(search, sources: sources, account: account, token: token, now: Date())
        return PresetFetch(items: found.items, totalCount: found.totalCount, isComplete: found.isComplete,
                           requests: await counter.count)
    }

    /// A provider that sends through `client`.
    private init(client: GitHubClient) {
        self.client = client
    }

    private func searchPreset(
        _ search: PresetSearch, sources: [SearchSource], account: Account, token: String, now: Date
    ) async throws -> (items: [WorkItem], totalCount: Int, isComplete: Bool) {
        let endpoints = GitHubEndpoints(baseURL: account.baseURL)
        // Resolved lazily, once per fetch, as in `fetchItems`.
        let teams = TeamSlugs()
        var items: [WorkItem] = []
        var seen: Set<String> = []
        var totalCount = 0
        var isComplete = true
        for kind in search.kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            let terms = PresetSearchQuery.filterTerms(for: search.filter, kind: kind, now: now)
            for query in Self.presetQueries(kind: kind, sources: sources, filterTerms: terms, sort: search.sort) {
                let result = try await run(query, kind: kind, account: account, token: token, endpoints: endpoints, teams: teams)
                items += result.items.filter { seen.insert($0.id).inserted }
                totalCount += result.totalCount
                isComplete = isComplete && result.isComplete
            }
        }
        return (items, totalCount, isComplete)
    }

    /// Pages through one search until GitHub has no further page or ``GraphQLQueries/maxPresetSearchResults`` results
    /// were read. Complete only when GitHub ran out of pages and counted no more than that.
    private func run(
        _ query: PresetQuery, kind: ItemKind, account: Account, token: String, endpoints: GitHubEndpoints, teams: TeamSlugs
    ) async throws -> (items: [WorkItem], totalCount: Int, isComplete: Bool) {
        let document = GraphQLQueries.presetSearch(kind: kind)
        let cap = GraphQLQueries.maxPresetSearchResults
        let pageSize = GraphQLQueries.presetSearchPageSize(for: kind)
        var items: [WorkItem] = []
        var totalCount = 0
        var read = 0
        var after: String?
        var isComplete = false
        // No more pages than hold the cap, so pages that come back short cannot keep the search going.
        for _ in 0..<(cap + pageSize - 1) / pageSize {
            let response = try await client.graphQL(SearchData.self, endpoint: endpoints.graphQL, token: token, query: document,
                                                    variables: ["q": query.text, "after": after])
            guard let search = response.data?.search else { break }
            if let errors = response.errors, !errors.isEmpty {
                gitHubLog.info("A preset search page came with \(errors.count) GraphQL errors beside its results")
            }
            totalCount = search.issueCount
            read += search.nodes.count

            let matching: [(node: ItemNode, repository: String)] = search.items.compactMap { node in
                guard (node.__typename == "PullRequest") == (kind == .pullRequest),
                      let repository = node.repository?.nameWithOwner, query.covers(repository) else { return nil }
                return (node, repository)
            }
            let slugs = await teamSlugs(for: matching.map(\.node), account: account, token: token, endpoints: endpoints, teams: teams)
            items += matching.map {
                GraphQLMapping.workItem($0.node, kind: kind, accountID: account.id, fallbackRepository: $0.repository,
                                        viewer: account.me, teamSlugs: slugs)
            }

            guard let pageInfo = search.pageInfo, pageInfo.hasNextPage else {
                isComplete = totalCount <= cap
                break
            }
            guard read < cap, let cursor = pageInfo.endCursor else { break }
            after = cursor
        }
        if totalCount > cap {
            gitHubLog.warning("A preset search matches \(totalCount) items; GitHub returns the first \(cap)")
        }
        return (items, totalCount, isComplete)
    }

    // MARK: Sources and length

    /// The scope's repositories, else the account's organizations and repositories in the account's order. Names GitHub
    /// cannot have are left out, so they can never change the meaning of the search.
    private static func presetSources(account: Account, repositories: Set<String>?) -> [SearchSource] {
        let candidates: [SearchSource]
        if let repositories {
            candidates = repositories.sorted().map(SearchSource.repository)
        } else {
            candidates = account.sources.compactMap { source in
                switch source {
                case .organization(let login): .organization(login)
                case .repository(let fullName): .repository(fullName)
                case .group: nil
                }
            }
        }
        let valid = candidates.filter(\.isValid)
        if valid.count < candidates.count {
            gitHubLog.error("Preset search leaves out \(candidates.count - valid.count) sources whose names GitHub cannot have")
        }
        var seen: Set<String> = []
        return valid.filter { seen.insert($0.qualifier.lowercased()).inserted }
    }

    /// The searches for one kind: every source in one OR group while the search fits
    /// ``GraphQLQueries/maxPresetSearchQueryLength``, else as many groups as it takes. When the filter does not fit beside
    /// even the longest source, its longest top-level terms are left out until it does. That only widens the search, and
    /// `FilterEngine` still decides what the preset shows; kind, state, sources and `archived:false` always stay.
    private static func presetQueries(
        kind: ItemKind, sources: [SearchSource], filterTerms: [String], sort: GitwallCore.SortOrder
    ) -> [PresetQuery] {
        let limit = GraphQLQueries.maxPresetSearchQueryLength
        func text(_ group: [SearchSource], _ terms: [String]) -> String {
            PresetSearchQuery.query(kind: kind, sources: group.map(\.qualifier), filterTerms: terms, sort: sort)
        }

        var terms = filterTerms
        if let longest = sources.max(by: { $0.qualifier.utf8.count < $1.qualifier.utf8.count }) {
            while text([longest], terms).utf8.count > limit,
                  let index = terms.indices.max(by: { terms[$0].utf8.count < terms[$1].utf8.count }) {
                terms.remove(at: index)
            }
        }
        if terms.count < filterTerms.count {
            gitHubLog.info("Preset search leaves out \(filterTerms.count - terms.count) of \(filterTerms.count) filter terms to stay within \(limit) characters")
        }

        var groups: [[SearchSource]] = []
        for source in sources {
            if let last = groups.last, text(last + [source], terms).utf8.count <= limit {
                groups[groups.count - 1].append(source)
            } else {
                groups.append([source])
            }
        }
        if groups.count > 1 {
            gitHubLog.info("Preset search splits \(sources.count) sources over \(groups.count) searches to stay within \(limit) characters")
        }
        return groups.map { PresetQuery(text: text($0, terms), sources: $0) }
    }
}

/// An organization or repository as a preset search names it.
private enum SearchSource: Hashable {
    case organization(String)
    case repository(String)

    var qualifier: String {
        switch self {
        case .organization(let login): "org:\(login)"
        case .repository(let fullName): "repo:\(fullName)"
        }
    }

    var isValid: Bool {
        switch self {
        case .organization(let login): PresetSearchQuery.isOwner(login)
        case .repository(let fullName): GraphQLQueries.splitFullName(fullName) != nil
        }
    }
}

/// One search string and the sources it names, which decide whose items it may return.
private struct PresetQuery {
    let text: String
    private let owners: Set<String>
    private let repositories: Set<String>

    init(text: String, sources: [SearchSource]) {
        self.text = text
        var owners: Set<String> = []
        var repositories: Set<String> = []
        for source in sources {
            switch source {
            case .organization(let login): owners.insert(login.lowercased())
            case .repository(let fullName): repositories.insert(fullName.lowercased())
            }
        }
        self.owners = owners
        self.repositories = repositories
    }

    /// GitHub compares owners and names without case.
    func covers(_ fullName: String) -> Bool {
        let name = fullName.lowercased()
        guard let owner = name.split(separator: "/").first else { return false }
        return repositories.contains(name) || owners.contains(String(owner))
    }
}

/// Counts the requests of one preset fetch on their way to the real transport.
private actor RequestCounter: HTTPTransport {
    private let transport: any HTTPTransport
    private(set) var count = 0

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return try await transport.send(request)
    }
}
