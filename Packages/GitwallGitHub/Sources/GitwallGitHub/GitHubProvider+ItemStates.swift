import Foundation
import GitwallCore

// MARK: - Item states

extension GitHubProvider {
    /// The state of each item by its node id, in batches of ``GraphQLQueries/maxItemStateLookupsPerRequest``, for items
    /// that left a preset search. A pull request is open, closed or merged, an issue open or closed; an open one comes
    /// back mapped like a search hit, team review requests included. A null node is an id GitHub cannot resolve or the
    /// token may no longer see, so it is not found, unless an error of another type points at it. An item without a
    /// usable node id, a node of another type and a state GitHub does not document get no answer.
    ///
    /// Errors are those of every request: a refused token is `.unauthorized`, a rate limit `.rateLimited`, GraphQL
    /// errors without data `.server(status: 200, …)`, a rejected request `.server(status:…)` with its status.
    public func fetchItemStates(account: Account, token: String, items: [WorkItem]) async throws -> [String: ItemState] {
        var asked: [String: WorkItem] = [:]
        for item in items {
            guard let nodeID = item.nodeID, GraphQLQueries.isNodeID(nodeID) else { continue }
            asked[nodeID] = item
        }
        guard !asked.isEmpty else { return [:] }

        let endpoints = GitHubEndpoints(baseURL: account.baseURL)
        // Resolved lazily, once per lookup, as in `fetchItems`.
        let teams = TeamSlugs()
        let nodeIDs = asked.keys.sorted()
        let size = GraphQLQueries.maxItemStateLookupsPerRequest
        var states: [String: ItemState] = [:]
        for start in stride(from: 0, to: nodeIDs.count, by: size) {
            let batch = Array(nodeIDs[start..<min(start + size, nodeIDs.count)])
            let response = try await client.graphQL(ItemStatesData.self, endpoint: endpoints.graphQL, token: token,
                                                    query: GraphQLQueries.itemStates(nodeIDs: batch))
            let nodes = response.data?.nodes ?? []
            let errors = response.errors ?? []
            if errors.contains(where: { $0.type?.uppercased() != "NOT_FOUND" }) {
                gitHubLog.info("An item state lookup came with \(errors.count) GraphQL errors beside its results")
            }
            let open = nodes.compactMap { $0?.state == "OPEN" ? $0?.item : nil }
            let slugs = await teamSlugs(for: open, account: account, token: token, endpoints: endpoints, teams: teams)
            for (index, nodeID) in batch.enumerated() where index < nodes.count {
                guard let item = asked[nodeID] else { continue }
                guard let node = nodes[index] else {
                    if Self.isUnresolved(index, errors: errors) { states[item.id] = .notFound }
                    continue
                }
                guard let kind = node.kind, let fields = node.item, fields.id == nodeID else { continue }
                switch node.state {
                case "OPEN":
                    states[item.id] = .open(GraphQLMapping.workItem(
                        fields, kind: kind, accountID: account.id, fallbackRepository: item.repoFullName,
                        viewer: account.me, teamSlugs: slugs
                    ))
                case "CLOSED":
                    states[item.id] = .closed
                case "MERGED":
                    states[item.id] = .merged
                default:
                    continue
                }
            }
        }
        return states
    }

    /// A null node is an id GitHub could not resolve, unless an error of another type points at it, such as a field
    /// that failed and took its non-null parent with it.
    private static func isUnresolved(_ index: Int, errors: [GraphQLError]) -> Bool {
        errors.filter { $0.path?.starts(with: [.key("nodes"), .index(index)]) == true }
            .allSatisfy { $0.type?.uppercased() == "NOT_FOUND" }
    }
}
