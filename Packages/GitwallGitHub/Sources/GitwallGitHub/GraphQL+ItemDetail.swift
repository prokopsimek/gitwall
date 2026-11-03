import Foundation
import GitwallCore

// MARK: - Queries

/// Detail of one pull request or issue, by repository and number, so it works for snapshots without node ids. Two
/// queries instead of one: the checks and files may need permissions the conversation does not, and GitHub refuses a
/// whole query when one field is refused (see `docs/adr/0012` for the same reasoning about priorities). Both are reads.
extension GraphQLQueries {
    static let detailComments = 20
    static let detailReviews = 10
    static let detailEvents = 30
    static let detailLinks = 10
    static let detailFiles = 100
    static let detailChecks = 100

    private static let actor = "__typename login avatarUrl"

    /// Body, the last comments, reviews and timeline events, and the linked items. One query for both kinds.
    static func itemConversation(number: Int) -> String {
        """
        query($owner: String!, $name: String!) {
          \(rateLimitField)
          repository(owner: $owner, name: $name) {
            issueOrPullRequest(number: \(number)) {
              __typename
              ... on Issue {
                body
                comments(last: \(detailComments)) { nodes { id url body createdAt author { \(actor) } } }
                timelineItems(last: \(detailEvents), itemTypes: [ISSUE_COMMENT, LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT]) {
                  nodes { __typename ...Events }
                }
                closedByPullRequestsReferences(first: \(detailLinks), includeClosedPrs: true) { nodes { ...Linked } }
              }
              ... on PullRequest {
                body headRefName baseRefName
                comments(last: \(detailComments)) { nodes { id url body createdAt author { \(actor) } } }
                reviews(last: \(detailReviews)) { nodes { id url body state submittedAt createdAt author { \(actor) } } }
                timelineItems(last: \(detailEvents), itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, LABELED_EVENT, \
        UNLABELED_EVENT, READY_FOR_REVIEW_EVENT, REVIEW_REQUESTED_EVENT, ASSIGNED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
                  nodes { __typename ...Events }
                }
                closingIssuesReferences(first: \(detailLinks)) { nodes { ...Linked } }
              }
            }
          }
        }
        fragment Linked on Node {
          ... on Issue { number title url state repository { nameWithOwner } }
          ... on PullRequest { number title url state repository { nameWithOwner } }
        }
        fragment Events on Node {
          id
          ... on IssueComment { url createdAt author { login } }
          ... on PullRequestReview { url state createdAt author { login } }
          ... on PullRequestCommit { url commit { abbreviatedOid messageHeadline committedDate author { user { login } } } }
          ... on LabeledEvent { createdAt actor { login } label { name } }
          ... on UnlabeledEvent { createdAt actor { login } label { name } }
          ... on ReadyForReviewEvent { createdAt actor { login } }
          ... on ReviewRequestedEvent { createdAt actor { login } requestedReviewer { __typename ... on User { login } ... on Team { slug } \
        ... on Bot { login } ... on Mannequin { login } } }
          ... on AssignedEvent { createdAt actor { login } assignee { __typename ... on User { login } ... on Bot { login } \
        ... on Mannequin { login } ... on Organization { login } } }
          ... on HeadRefForcePushedEvent { createdAt actor { login } afterCommit { abbreviatedOid } }
        }
        """
    }

    /// Checks and statuses of the last commit by name, and the first files. Pull requests only.
    static func itemStatus(number: Int) -> String {
        """
        query($owner: String!, $name: String!) {
          \(rateLimitField)
          repository(owner: $owner, name: $name) {
            issueOrPullRequest(number: \(number)) {
              __typename
              ... on PullRequest {
                changedFiles
                files(first: \(detailFiles)) { totalCount nodes { path additions deletions } }
                commits(last: 1) {
                  nodes {
                    commit {
                      oid
                      statusCheckRollup {
                        state
                        contexts(first: \(detailChecks)) {
                          nodes {
                            __typename
                            ... on CheckRun { name status conclusion detailsUrl url }
                            ... on StatusContext { context state targetUrl }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
    }
}

// MARK: - Response models

struct ItemDetailData: Decodable, RateLimitCarrying {
    struct Repository: Decodable { let issueOrPullRequest: DetailNode? }

    let rateLimitInfo: RateLimitInfo?
    let repository: Repository?

    enum CodingKeys: String, CodingKey {
        case rateLimitInfo = "rateLimit"
        case repository
    }
}

/// The union of both detail queries; each fills its own fields.
struct DetailNode: Decodable {
    struct Actor: Decodable {
        let __typename: String?
        let login: String?
        let avatarUrl: URL?
    }
    struct Comment: Decodable {
        let id: String?
        let url: URL?
        let body: String?
        let createdAt: Date
        let author: Actor?
    }
    struct Review: Decodable {
        let id: String?
        let url: URL?
        let body: String?
        let state: String?
        let submittedAt: Date?
        let createdAt: Date?
        let author: Actor?
    }
    struct Linked: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        let number: Int?
        let title: String?
        let url: URL?
        let state: String?
        let repository: Repository?
    }
    struct Event: Decodable {
        struct Label: Decodable { let name: String }
        struct Commit: Decodable {
            struct Author: Decodable { let user: Actor? }
            let abbreviatedOid: String?
            let messageHeadline: String?
            let committedDate: Date?
            let author: Author?
        }
        struct Reviewer: Decodable {
            let login: String?
            let slug: String?
        }

        let __typename: String
        let id: String?
        let url: URL?
        let createdAt: Date?
        let state: String?
        let author: Actor?
        let actor: Actor?
        let label: Label?
        let commit: Commit?
        let requestedReviewer: Reviewer?
        let assignee: Reviewer?
        let afterCommit: Commit?
    }
    struct Files: Decodable {
        struct File: Decodable {
            let path: String
            let additions: Int?
            let deletions: Int?
        }
        let totalCount: Int?
        let nodes: [File?]
    }
    struct LastCommit: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable {
                struct Context: Decodable {
                    let __typename: String?
                    let name: String?
                    let status: String?
                    let conclusion: String?
                    let detailsUrl: URL?
                    let url: URL?
                    let context: String?
                    let state: String?
                    let targetUrl: URL?
                }
                let contexts: Connection<Context>?
            }
            let statusCheckRollup: Rollup?
        }
        let commit: Commit?
    }

    let __typename: String?
    let body: String?
    let headRefName: String?
    let baseRefName: String?
    let comments: Connection<Comment>?
    let reviews: Connection<Review>?
    let timelineItems: Connection<Event>?
    let closingIssuesReferences: Connection<Linked>?
    let closedByPullRequestsReferences: Connection<Linked>?
    let changedFiles: Int?
    let files: Files?
    let commits: Connection<LastCommit>?
}

// MARK: - Mapping

enum DetailMapping {
    static func user(_ actor: DetailNode.Actor?) -> UserRef {
        guard let login = actor?.login, !login.isEmpty else { return UserRef(login: "ghost") }
        return UserRef(login: login, avatarURL: actor?.avatarUrl)
    }

    static func comments(_ connection: Connection<DetailNode.Comment>?) -> [DetailComment] {
        (connection?.items ?? []).enumerated().map { index, node in
            DetailComment(id: node.id ?? "comment-\(index)", author: user(node.author), body: node.body ?? "",
                          createdAt: node.createdAt, url: node.url)
        }
    }

    static func reviews(_ connection: Connection<DetailNode.Review>?) -> [DetailReview] {
        (connection?.items ?? []).enumerated().compactMap { index, node in
            guard let date = node.submittedAt ?? node.createdAt else { return nil }
            return DetailReview(id: node.id ?? "review-\(index)", author: user(node.author), verdict: verdict(node.state),
                                body: node.body ?? "", submittedAt: date, url: node.url)
        }
    }

    static func verdict(_ state: String?) -> ReviewVerdict {
        switch state {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "DISMISSED": .dismissed
        case "PENDING": .pending
        default: .commented
        }
    }

    /// Events of a type Gitwall does not show, or without a date, are left out.
    static func timeline(_ connection: Connection<DetailNode.Event>?) -> [TimelineEvent] {
        (connection?.items ?? []).enumerated().compactMap { index, node in
            let id = node.id ?? "\(node.__typename)-\(index)"
            func event(_ kind: TimelineEvent.Kind, by actor: DetailNode.Actor?, at date: Date?) -> TimelineEvent? {
                guard let date else { return nil }
                let login = actor?.login.flatMap { $0.isEmpty ? nil : UserRef(login: $0) }
                return TimelineEvent(id: id, kind: kind, actor: login, createdAt: date, url: node.url)
            }
            switch node.__typename {
            case "IssueComment":
                return event(.commented, by: node.author, at: node.createdAt)
            case "PullRequestReview":
                return event(.reviewed(verdict(node.state)), by: node.author, at: node.createdAt)
            case "PullRequestCommit":
                guard let commit = node.commit else { return nil }
                return event(.committed(sha: commit.abbreviatedOid ?? "", message: commit.messageHeadline ?? ""),
                             by: commit.author?.user, at: commit.committedDate)
            case "LabeledEvent":
                return event(.labeled(node.label?.name ?? ""), by: node.actor, at: node.createdAt)
            case "UnlabeledEvent":
                return event(.unlabeled(node.label?.name ?? ""), by: node.actor, at: node.createdAt)
            case "ReadyForReviewEvent":
                return event(.readyForReview, by: node.actor, at: node.createdAt)
            case "ReviewRequestedEvent":
                let reviewer = node.requestedReviewer?.login ?? node.requestedReviewer?.slug ?? "ghost"
                return event(.reviewRequested(reviewer), by: node.actor, at: node.createdAt)
            case "AssignedEvent":
                return event(.assigned(node.assignee?.login ?? "ghost"), by: node.actor, at: node.createdAt)
            case "HeadRefForcePushedEvent":
                return event(.forcePushed(sha: node.afterCommit?.abbreviatedOid), by: node.actor, at: node.createdAt)
            default:
                return nil
            }
        }
    }

    static func linked(_ connection: Connection<DetailNode.Linked>?, kind: ItemKind) -> [LinkedItem] {
        (connection?.items ?? []).compactMap { node in
            guard let number = node.number, let url = node.url, let repository = node.repository?.nameWithOwner else { return nil }
            let state: LinkedItem.State = switch node.state {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
            return LinkedItem(kind: kind, repoFullName: repository, number: number, title: node.title ?? "", url: url, state: state)
        }
    }

    static func checks(_ commits: Connection<DetailNode.LastCommit>?) -> [DetailCheck] {
        let contexts = commits?.items.last?.commit?.statusCheckRollup?.contexts?.items ?? []
        return contexts.compactMap { context in
            if context.__typename == "StatusContext" {
                guard let name = context.context else { return nil }
                return DetailCheck(name: name, state: statusState(context.state), url: context.targetUrl)
            }
            guard let name = context.name else { return nil }
            return DetailCheck(name: name, state: checkRunState(status: context.status, conclusion: context.conclusion),
                               url: context.detailsUrl ?? context.url)
        }
    }

    /// A check run that has not completed is running; a completed one is judged by its conclusion. Cancelled and
    /// timed out runs block a merge the way failures do, so they count as failed.
    static func checkRunState(status: String?, conclusion: String?) -> CheckState {
        guard status == "COMPLETED" else { return .running }
        switch conclusion {
        case "SUCCESS": return .passed
        case "NEUTRAL", "SKIPPED", "STALE": return .skipped
        default: return .failed
        }
    }

    static func statusState(_ state: String?) -> CheckState {
        switch state {
        case "SUCCESS": .passed
        case "FAILURE", "ERROR": .failed
        default: .running
        }
    }

    static func files(_ node: DetailNode) -> ChangedFiles {
        let files = (node.files?.nodes ?? []).compactMap { $0 }.map {
            ChangedFile(path: $0.path, additions: $0.additions ?? 0, deletions: $0.deletions ?? 0)
        }
        return ChangedFiles(files: files, totalCount: node.files?.totalCount ?? node.changedFiles ?? files.count)
    }
}
