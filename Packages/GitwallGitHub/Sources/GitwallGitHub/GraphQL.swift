import Foundation
import GitwallCore

// MARK: - Queries

enum GraphQLQueries {
    static let maxRepositoriesPerBatch = 15
    static let pageSize = 50
    static let maxExtraPagesPerRepository = 3
    static let searchPageSize = 100
    static let maxSearchPages = 3
    static let maxSearchQueryLength = 256

    static let pullRequestFragment = """
    fragment PR on PullRequest {
      number title url isDraft createdAt updatedAt
      author { login avatarUrl ... on User { name } }
      labels(first: 20) { nodes { name color } }
      assignees(first: 10) { nodes { login name avatarUrl } }
      milestone { title }
      comments { totalCount }
      reviewDecision mergeable additions deletions
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login name avatarUrl } ... on Team { slug name } } } }
      latestReviews(first: 20) { nodes { state author { login avatarUrl } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      repository { nameWithOwner }
    }
    """

    static let issueFragment = """
    fragment Issue on Issue {
      number title url createdAt updatedAt
      author { login avatarUrl ... on User { name } }
      labels(first: 20) { nodes { name color } }
      assignees(first: 10) { nodes { login name avatarUrl } }
      milestone { title }
      comments { totalCount }
      repository { nameWithOwner }
    }
    """

    /// GitHub rejects queries that define a fragment without using it, so only emit the needed ones.
    static func fragments(for kinds: Set<ItemKind>) -> String {
        var parts: [String] = []
        if kinds.contains(.pullRequest) { parts.append(pullRequestFragment) }
        if kinds.contains(.issue) { parts.append(issueFragment) }
        return parts.joined(separator: "\n")
    }

    static let rateLimitField = "rateLimit { cost remaining resetAt }"

    static func connections(for kinds: Set<ItemKind>, after cursor: String? = nil) -> String {
        let after = cursor.map { ", after: \"\($0)\"" } ?? ""
        var parts: [String] = []
        if kinds.contains(.pullRequest) {
            parts.append("pullRequests(states: OPEN, first: \(pageSize)\(after), orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { ...PR } }")
        }
        if kinds.contains(.issue) {
            parts.append("issues(states: OPEN, first: \(pageSize)\(after), orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { ...Issue } }")
        }
        return parts.joined(separator: " ")
    }

    /// One request for up to `maxRepositoriesPerBatch` repositories, aliased r0…rN.
    static func repositoryBatch(_ repositories: [(owner: String, name: String)], kinds: Set<ItemKind>) -> String {
        var query = "query {\n  \(rateLimitField)\n"
        for (index, repo) in repositories.enumerated() {
            query += "  r\(index): repository(owner: \"\(repo.owner)\", name: \"\(repo.name)\") { nameWithOwner isArchived \(connections(for: kinds)) }\n"
        }
        query += "}\n" + fragments(for: kinds)
        return query
    }

    /// Follow-up page for a single repository and kind.
    static func repositoryPage(owner: String, name: String, kind: ItemKind, after cursor: String) -> String {
        "query {\n  \(rateLimitField)\n  r0: repository(owner: \"\(owner)\", name: \"\(name)\") { nameWithOwner isArchived \(connections(for: [kind], after: cursor)) }\n}\n" + fragments(for: [kind])
    }

    /// Teams the token owner belongs to, so review requests addressed to a team can be resolved.
    /// Classic tokens need `read:org`; without it GitHub answers with an error and Gitwall carries on without teams.
    static let viewerTeams = """
    query {
      viewer {
        organizations(first: 100) {
          nodes { login teams(first: 100, role: MEMBER) { nodes { slug } } }
        }
      }
    }
    """

    static let search = """
    query($q: String!, $after: String) {
      \(rateLimitField)
      search(query: $q, type: ISSUE, first: \(searchPageSize), after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes { __typename ... on PullRequest { ...PR } ... on Issue { ...Issue } }
      }
    }
    """ + fragments(for: [.pullRequest, .issue])

    static func searchQuery(organization: String, kind: ItemKind, nativeQuery: String?) throws -> String {
        var parts = ["org:\(organization)", kind == .pullRequest ? "is:pr" : "is:issue", "is:open", "archived:false", "sort:updated-desc"]
        if let nativeQuery = nativeQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !nativeQuery.isEmpty {
            parts.append(nativeQuery)
        }
        let query = parts.joined(separator: " ")
        guard query.count <= maxSearchQueryLength else {
            throw ProviderError.invalidResponse("The search query for organization \(organization) exceeds GitHub's \(maxSearchQueryLength)-character limit. Shorten the native query.")
        }
        return query
    }

    /// GitHub repository owners and names: letters, digits, `-`, `_`, `.`.
    static func splitFullName(_ fullName: String) -> (owner: String, name: String)? {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for part in parts where part.isEmpty || part.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }
}

// MARK: - Response models

struct RepositoryBatchData: Decodable, RateLimitCarrying {
    let rateLimitInfo: RateLimitInfo?
    /// Alias → repository (nil when GitHub could not resolve it).
    let repositories: [String: RepositoryNode?]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var repositories: [String: RepositoryNode?] = [:]
        var rateLimit: RateLimitInfo?
        for key in container.allKeys {
            if key.stringValue == "rateLimit" {
                rateLimit = try container.decodeIfPresent(RateLimitInfo.self, forKey: key)
            } else {
                repositories[key.stringValue] = try container.decodeIfPresent(RepositoryNode.self, forKey: key)
            }
        }
        self.repositories = repositories
        rateLimitInfo = rateLimit
    }
}

struct ViewerTeamsData: Decodable {
    struct Viewer: Decodable {
        struct Organization: Decodable {
            struct Team: Decodable { let slug: String }
            let login: String
            let teams: Connection<Team>?
        }
        let organizations: Connection<Organization>?
    }
    let viewer: Viewer?

    /// `owner/slug`, lowercased, ready to compare with a review request on a repository of that owner.
    var slugs: Set<String> {
        Set((viewer?.organizations?.items ?? []).flatMap { organization in
            (organization.teams?.items ?? []).map { "\(organization.login.lowercased())/\($0.slug.lowercased())" }
        })
    }
}

struct SearchData: Decodable, RateLimitCarrying {
    let rateLimitInfo: RateLimitInfo?
    let search: Connection<ItemNode>

    enum CodingKeys: String, CodingKey {
        case rateLimitInfo = "rateLimit"
        case search
    }
}

struct RepositoryNode: Decodable {
    let nameWithOwner: String
    /// Nothing in an archived repository can be merged or closed; its items are dropped before mapping.
    let isArchived: Bool?
    let pullRequests: Connection<ItemNode>?
    let issues: Connection<ItemNode>?
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

/// Union of the PullRequest and Issue fragments; issue-only responses leave the PR fields nil.
struct ItemNode: Decodable {
    struct Actor: Decodable {
        let login: String?
        let name: String?
        let avatarUrl: URL?
    }
    struct LabelNode: Decodable {
        let name: String
        let color: String?
    }
    struct Milestone: Decodable { let title: String }
    struct Count: Decodable { let totalCount: Int }
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable {
            let __typename: String?
            let login: String?
            let name: String?
            let avatarUrl: URL?
            let slug: String?
        }
        let requestedReviewer: Reviewer?
    }
    struct Review: Decodable {
        let state: String?
        let author: Actor?
    }
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: String? }
            let statusCheckRollup: Rollup?
        }
        let commit: Commit?
    }
    struct Repository: Decodable { let nameWithOwner: String }

    let __typename: String?
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool?
    let createdAt: Date
    let updatedAt: Date
    let author: Actor?
    let labels: Connection<LabelNode>?
    let assignees: Connection<Actor>?
    let milestone: Milestone?
    let comments: Count?
    let reviewDecision: String?
    let mergeable: String?
    let additions: Int?
    let deletions: Int?
    let reviewRequests: Connection<ReviewRequest>?
    let latestReviews: Connection<Review>?
    let commits: Connection<CommitNode>?
    let repository: Repository?
}

// MARK: - Mapping

enum GraphQLMapping {
    /// - Parameters:
    ///   - viewer: the token owner, when known. A review request addressed to one of their teams resolves to them.
    ///   - teamSlugs: `owner/slug`, lowercased, of the teams the viewer belongs to.
    static func workItem(
        _ node: ItemNode,
        kind: ItemKind,
        accountID: UUID,
        fallbackRepository: String,
        viewer: UserRef? = nil,
        teamSlugs: Set<String> = []
    ) -> WorkItem {
        let repo = node.repository?.nameWithOwner ?? fallbackRepository
        let author = userRef(login: node.author?.login, name: node.author?.name, avatar: node.author?.avatarUrl)
        let labels = node.labels?.items.map { Label(name: $0.name, colorHex: $0.color) } ?? []
        let assignees = node.assignees?.items.compactMap { userRef(login: $0.login, name: $0.name, avatar: $0.avatarUrl, optional: true) } ?? []

        guard kind == .pullRequest else {
            return WorkItem(
                accountID: accountID, kind: .issue, repoFullName: repo, number: node.number, title: node.title, url: node.url,
                author: author, createdAt: node.createdAt, updatedAt: node.updatedAt, isDraft: false,
                labels: labels, assignees: assignees, milestone: node.milestone?.title,
                commentCount: node.comments?.totalCount ?? 0
            )
        }

        let owner = repo.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        var requested: [UserRef] = []
        for request in node.reviewRequests?.items ?? [] {
            guard let reviewer = request.requestedReviewer else { continue }
            if reviewer.__typename == "Team" {
                // GitHub asks the team, not the person. Resolve it only for teams the viewer is in, so the
                // item lands in their review queue; everyone else's teams stay out of it.
                guard let viewer, let slug = reviewer.slug, teamSlugs.contains("\(owner)/\(slug.lowercased())") else { continue }
                requested.append(viewer)
            } else if let user = userRef(login: reviewer.login, name: reviewer.name, avatar: reviewer.avatarUrl, optional: true) {
                requested.append(user)
            }
        }
        var seenReviewers: Set<String> = []
        requested = requested.filter { seenReviewers.insert($0.login.lowercased()).inserted }
        let reviews = node.latestReviews?.items ?? []
        let reviewers = reviews.compactMap { userRef(login: $0.author?.login, name: nil, avatar: $0.author?.avatarUrl, optional: true) }

        return WorkItem(
            accountID: accountID, kind: .pullRequest, repoFullName: repo, number: node.number, title: node.title, url: node.url,
            author: author, createdAt: node.createdAt, updatedAt: node.updatedAt, isDraft: node.isDraft ?? false,
            labels: labels, assignees: assignees, milestone: node.milestone?.title,
            commentCount: node.comments?.totalCount ?? 0,
            reviewState: reviewState(decision: node.reviewDecision, reviews: reviews, hasRequests: !(node.reviewRequests?.items.isEmpty ?? true)),
            ciState: ciState(node.commits?.items.first?.commit?.statusCheckRollup?.state),
            mergeState: mergeState(node.mergeable),
            reviewers: reviewers,
            requestedReviewers: requested,
            additions: node.additions,
            deletions: node.deletions
        )
    }

    static func reviewState(decision: String?, reviews: [ItemNode.Review], hasRequests: Bool) -> ReviewState {
        switch decision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .pending
        default: break
        }
        let states = Set(reviews.compactMap(\.state))
        if states.contains("APPROVED") { return .approved }
        if states.contains("CHANGES_REQUESTED") { return .changesRequested }
        return hasRequests ? .pending : .none
    }

    static func ciState(_ rollup: String?) -> CIState {
        switch rollup {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .running
        default: .none
        }
    }

    static func mergeState(_ mergeable: String?) -> MergeState {
        switch mergeable {
        case "MERGEABLE": .clean
        case "CONFLICTING": .conflict
        default: .unknown
        }
    }

    private static func userRef(login: String?, name: String?, avatar: URL?, optional: Bool = false) -> UserRef? {
        guard let login, !login.isEmpty else {
            // Deleted accounts show up as null authors ("ghost").
            return optional ? nil : UserRef(login: "ghost")
        }
        return UserRef(login: login, displayName: name, avatarURL: avatar)
    }

    private static func userRef(login: String?, name: String?, avatar: URL?) -> UserRef {
        userRef(login: login, name: name, avatar: avatar, optional: false)!
    }
}
