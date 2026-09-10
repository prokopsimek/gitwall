import Foundation
import GitwallCore

// MARK: - Queries

enum GitLabQueries {
    /// One project with both connections at 50 items costs ~150 complexity points (limit 200/250),
    /// so every source gets its own request.
    static let pageSize = 50
    static let maxExtraPages = 3

    static func mergeRequestFragment(interaction: Bool) -> String {
        let reviewer = interaction
            ? "reviewers { nodes { username name avatarUrl mergeRequestInteraction { reviewState approved } } }"
            : "reviewers { nodes { username name avatarUrl } }"
        return """
        iid title webUrl draft createdAt updatedAt
        author { username name avatarUrl }
        labels { nodes { title color } }
        assignees { nodes { username name avatarUrl } }
        \(reviewer)
        milestone { title }
        userNotesCount approved conflicts detailedMergeStatus
        approvedBy { nodes { username } }
        headPipeline { status }
        diffStatsSummary { additions deletions }
        project { fullPath }
        """
    }

    static let issueFragment = """
    iid title webUrl createdAt updatedAt
    author { username name avatarUrl }
    labels { nodes { title color } }
    assignees { nodes { username name avatarUrl } }
    milestone { title }
    userNotesCount
    """

    /// Builds a project or group query for the requested connections.
    /// Variables: `path`, `subgroups` (groups only), `mrAfter`, `issueAfter`.
    static func query(for source: RepoSource, kinds: Set<ItemKind>, interaction: Bool) -> String {
        let isGroup: Bool
        if case .group = source { isGroup = true } else { isGroup = false }
        let scope = isGroup ? "includeSubgroups: $subgroups, " : ""
        var connections: [String] = []
        if kinds.contains(.pullRequest) {
            connections.append("mergeRequests(\(scope)state: opened, first: \(pageSize), after: $mrAfter, sort: UPDATED_DESC) { pageInfo { hasNextPage endCursor } nodes { \(mergeRequestFragment(interaction: interaction)) } }")
        }
        if kinds.contains(.issue) {
            connections.append("issues(\(scope)state: opened, first: \(pageSize), after: $issueAfter, sort: UPDATED_DESC) { pageInfo { hasNextPage endCursor } nodes { \(issueFragment) } }")
        }
        let variables = isGroup
            ? "$path: ID!, $subgroups: Boolean!, $mrAfter: String, $issueAfter: String"
            : "$path: ID!, $mrAfter: String, $issueAfter: String"
        let root = isGroup ? "group(fullPath: $path)" : "project(fullPath: $path)"
        return """
        query(\(variables)) {
          queryComplexity { score limit }
          \(root) {
            fullPath
            \(connections.joined(separator: "\n    "))
          }
        }
        """
    }
}

// MARK: - Response models

/// `data` of a project/group query. The root field may be aliased, so the first container-like value wins.
struct ContainerData: Decodable {
    let complexity: Complexity?
    /// nil when GitLab could not resolve the project/group (returns `null`).
    let container: ContainerNode?
    let containerPresent: Bool

    struct Complexity: Decodable {
        let score: Int
        let limit: Int
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var complexity: Complexity?
        var node: ContainerNode?
        var present = false
        for key in container.allKeys {
            if key.stringValue == "queryComplexity" {
                complexity = try container.decodeIfPresent(Complexity.self, forKey: key)
            } else {
                present = true
                if let decoded = try container.decodeIfPresent(ContainerNode.self, forKey: key) {
                    node = decoded
                }
            }
        }
        self.complexity = complexity
        self.container = node
        containerPresent = present
    }
}

struct ContainerNode: Decodable {
    let fullPath: String?
    let mergeRequests: Connection<MergeRequestNode>?
    let issues: Connection<IssueNode>?
}

struct Connection<Node: Decodable>: Decodable {
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    let pageInfo: PageInfo?
    let nodes: [Node?]

    var items: [Node] { nodes.compactMap { $0 } }
}

struct UserNode: Decodable {
    struct Interaction: Decodable {
        let reviewState: String?
        let approved: Bool?
    }

    let username: String?
    let name: String?
    let avatarUrl: String?
    let mergeRequestInteraction: Interaction?
}

struct LabelNode: Decodable {
    let title: String
    let color: String?
}

struct Titled: Decodable { let title: String }
struct NamedRef: Decodable { let fullPath: String? }

struct MergeRequestNode: Decodable {
    struct Pipeline: Decodable { let status: String? }
    struct DiffStats: Decodable {
        let additions: Int?
        let deletions: Int?
    }

    let iid: String
    let title: String
    let webUrl: URL
    let draft: Bool?
    let createdAt: Date
    let updatedAt: Date
    let author: UserNode?
    let labels: Connection<LabelNode>?
    let assignees: Connection<UserNode>?
    let reviewers: Connection<UserNode>?
    let milestone: Titled?
    let userNotesCount: Int?
    let approved: Bool?
    let conflicts: Bool?
    let detailedMergeStatus: String?
    let approvedBy: Connection<UserNode>?
    let headPipeline: Pipeline?
    let diffStatsSummary: DiffStats?
    let project: NamedRef?
}

struct IssueNode: Decodable {
    let iid: String
    let title: String
    let webUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let author: UserNode?
    let labels: Connection<LabelNode>?
    let assignees: Connection<UserNode>?
    let milestone: Titled?
    let userNotesCount: Int?
}

// MARK: - Mapping

enum GitLabMapping {
    static func reviewState(approved: Bool, reviewerStates: [String], reviewerCount: Int) -> ReviewState {
        if approved { return .approved }
        if reviewerStates.contains("REQUESTED_CHANGES") { return .changesRequested }
        return reviewerCount > 0 ? .pending : .none
    }

    static func ciState(_ status: String?) -> CIState {
        switch status {
        case "SUCCESS": .success
        case "FAILED": .failure
        case "RUNNING", "PENDING", "CREATED", "PREPARING", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK", "SCHEDULED": .running
        default: .none
        }
    }

    static func mergeState(conflicts: Bool?, detailed: String?) -> MergeState {
        if conflicts == true { return .conflict }
        switch detailed {
        case "MERGEABLE": return .clean
        case "CONFLICT": return .conflict
        default: return .unknown
        }
    }

    /// "…/group/sub/project/-/merge_requests/1" → "group/sub/project".
    static func projectPath(from url: URL, baseURL: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/-/") {
            return String(path[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func user(_ node: UserNode?, endpoints: GitLabEndpoints) -> UserRef? {
        guard let node, let login = node.username, !login.isEmpty else { return nil }
        return UserRef(login: login, displayName: node.name, avatarURL: endpoints.resolve(avatar: node.avatarUrl))
    }

    static func labels(_ connection: Connection<LabelNode>?) -> [GitwallCore.Label] {
        connection?.items.map { GitwallCore.Label(name: $0.title, colorHex: $0.color?.replacingOccurrences(of: "#", with: "")) } ?? []
    }

    static func workItem(_ node: MergeRequestNode, accountID: UUID, endpoints: GitLabEndpoints) -> WorkItem {
        let reviewers = node.reviewers?.items ?? []
        let approvedBy = Set(node.approvedBy?.items.compactMap(\.username) ?? [])
        let states = reviewers.compactMap { $0.mergeRequestInteraction?.reviewState }
        let requested = reviewers.filter { reviewer in
            guard let login = reviewer.username else { return false }
            if let interaction = reviewer.mergeRequestInteraction {
                return interaction.approved != true && interaction.reviewState != "APPROVED"
            }
            return !approvedBy.contains(login)
        }
        return WorkItem(
            accountID: accountID,
            kind: .pullRequest,
            repoFullName: node.project?.fullPath ?? projectPath(from: node.webUrl, baseURL: endpoints.baseURL),
            number: Int(node.iid) ?? 0,
            title: node.title,
            url: node.webUrl,
            author: user(node.author, endpoints: endpoints) ?? UserRef(login: "ghost"),
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            isDraft: node.draft ?? false,
            labels: labels(node.labels),
            assignees: node.assignees?.items.compactMap { user($0, endpoints: endpoints) } ?? [],
            milestone: node.milestone?.title,
            commentCount: node.userNotesCount ?? 0,
            reviewState: reviewState(approved: node.approved ?? false, reviewerStates: states, reviewerCount: reviewers.count),
            ciState: ciState(node.headPipeline?.status),
            mergeState: mergeState(conflicts: node.conflicts, detailed: node.detailedMergeStatus),
            reviewers: reviewers.filter { $0.username.map(approvedBy.contains) ?? false }.compactMap { user($0, endpoints: endpoints) },
            requestedReviewers: requested.compactMap { user($0, endpoints: endpoints) },
            additions: node.diffStatsSummary?.additions,
            deletions: node.diffStatsSummary?.deletions
        )
    }

    static func workItem(_ node: IssueNode, accountID: UUID, endpoints: GitLabEndpoints) -> WorkItem {
        WorkItem(
            accountID: accountID,
            kind: .issue,
            repoFullName: projectPath(from: node.webUrl, baseURL: endpoints.baseURL),
            number: Int(node.iid) ?? 0,
            title: node.title,
            url: node.webUrl,
            author: user(node.author, endpoints: endpoints) ?? UserRef(login: "ghost"),
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            labels: labels(node.labels),
            assignees: node.assignees?.items.compactMap { user($0, endpoints: endpoints) } ?? [],
            milestone: node.milestone?.title,
            commentCount: node.userNotesCount ?? 0
        )
    }
}
