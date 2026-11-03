import Foundation
import GitwallCore

// MARK: - Item detail

extension GitHubProvider {
    /// Two read-only queries in parallel: the conversation, and for a pull request its checks and files. Each fails on
    /// its own, and inside each a field GitHub refuses fails only its own part. A refusal is a missing permission
    /// (Detail points to the token setup), anything else a passing failure. See `docs/adr/0015`.
    public func itemDetail(account: Account, token: String, item: WorkItem) async -> ItemDetail? {
        let fetchedAt = Date()
        guard let repository = GraphQLQueries.splitFullName(item.repoFullName) else {
            let error = DetailError.failed("“\(item.repoFullName)” is not a GitHub repository name.")
            let conversation = Self.conversation(.failure(error), isPullRequest: item.kind == .pullRequest)
            return Self.detail(item, fetchedAt: fetchedAt, conversation: conversation, status: Self.status(.failure(error)))
        }
        let request = Request(endpoint: GitHubEndpoints(baseURL: account.baseURL).graphQL, token: token,
                              variables: ["owner": repository.owner, "name": repository.name],
                              reference: "\(item.repoFullName)#\(item.number)")

        async let conversation = Self.conversation(
            await query(GraphQLQueries.itemConversation(number: item.number), request), isPullRequest: item.kind == .pullRequest
        )
        let status = item.kind == .pullRequest
            ? Self.status(await query(GraphQLQueries.itemStatus(number: item.number), request))
            : Self.status(.success(Answer(node: nil, errors: [])))
        return Self.detail(item, fetchedAt: fetchedAt, conversation: await conversation, status: status)
    }

    struct Request: Sendable {
        let endpoint: URL
        let token: String
        let variables: [String: String]
        /// `owner/repo#123`, for the log.
        let reference: String
    }

    /// The parts the conversation query fills, already mapped so they can leave the task that fetched them.
    struct ConversationParts: Sendable {
        var body: DetailSection<String>
        var branches: DetailSection<Branches?>
        var comments: DetailSection<[DetailComment]>
        var reviews: DetailSection<[DetailReview]>
        var timeline: DetailSection<[TimelineEvent]>
        var linkedItems: DetailSection<[LinkedItem]>
    }

    struct StatusParts: Sendable {
        var checks: DetailSection<[DetailCheck]>
        var files: DetailSection<ChangedFiles>
    }

    struct Answer {
        let node: DetailNode?
        let errors: [GraphQLError]
    }

    typealias QueryOutcome = Result<Answer, DetailError>

    private func query(_ query: String, _ request: Request) async -> QueryOutcome {
        let reference = request.reference
        do {
            let response = try await client.graphQL(ItemDetailData.self, endpoint: request.endpoint, token: request.token, query: query,
                                                    variables: request.variables)
            if let rateLimit = response.data?.rateLimitInfo {
                gitHubLog.info("Detail of \(reference, privacy: .public) cost \(rateLimit.cost), \(rateLimit.remaining) remaining")
            }
            let errors = response.errors ?? []
            guard let node = response.data?.repository?.issueOrPullRequest else {
                if let refused = errors.first(where: Self.refuses) {
                    gitHubLog.info("Detail of \(reference, privacy: .public) refused: \(refused.message, privacy: .public)")
                    return .failure(.missingPermission)
                }
                return .failure(.failed(errors.first?.message ?? "\(reference) was not found."))
            }
            return .success(Answer(node: node, errors: errors))
        } catch ProviderError.unauthorized {
            // `FORBIDDEN` or `INSUFFICIENT_SCOPES` without data. The lists were read with this token, so it is this
            // part the token may not read, not the token itself.
            gitHubLog.info("Detail of \(reference, privacy: .public) refused for this token")
            return .failure(.missingPermission)
        } catch {
            gitHubLog.info("Detail of \(reference, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.failed(error.localizedDescription))
        }
    }

    static func refuses(_ error: GraphQLError) -> Bool {
        switch error.type?.uppercased() {
        case "FORBIDDEN", "INSUFFICIENT_SCOPES": true
        default: false
        }
    }

    /// `value` unless an error's path runs through `field`, which then fails this part alone.
    static func section<Value>(_ outcome: QueryOutcome, field: String, _ value: (DetailNode) -> Value) -> DetailSection<Value> {
        switch outcome {
        case .failure(let error):
            return .failure(error)
        case .success(let answer):
            if let error = answer.errors.first(where: { $0.path?.contains(.key(field)) == true }) {
                return .failure(refuses(error) ? .missingPermission : .failed(error.message))
            }
            guard let node = answer.node else { return .success(value(.empty)) }
            return .success(value(node))
        }
    }

    static func conversation(_ outcome: QueryOutcome, isPullRequest: Bool) -> ConversationParts {
        ConversationParts(
            body: section(outcome, field: "body") { $0.body ?? "" },
            branches: section(outcome, field: "headRefName") { node in
                guard let head = node.headRefName, let base = node.baseRefName else { return nil }
                return Branches(head: head, base: base)
            },
            comments: section(outcome, field: "comments") { DetailMapping.comments($0.comments) },
            reviews: section(outcome, field: "reviews") { DetailMapping.reviews($0.reviews) },
            timeline: section(outcome, field: "timelineItems") { DetailMapping.timeline($0.timelineItems) },
            linkedItems: isPullRequest
                ? section(outcome, field: "closingIssuesReferences") { DetailMapping.linked($0.closingIssuesReferences, kind: .issue) }
                : section(outcome, field: "closedByPullRequestsReferences") {
                    DetailMapping.linked($0.closedByPullRequestsReferences, kind: .pullRequest)
                }
        )
    }

    static func status(_ outcome: QueryOutcome) -> StatusParts {
        StatusParts(
            checks: section(outcome, field: "statusCheckRollup") { DetailMapping.checks($0.commits) },
            files: section(outcome, field: "files") { DetailMapping.files($0) }
        )
    }

    static func detail(_ item: WorkItem, fetchedAt: Date, conversation: ConversationParts, status: StatusParts) -> ItemDetail {
        ItemDetail(
            itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: fetchedAt,
            body: conversation.body, branches: conversation.branches, comments: conversation.comments,
            reviews: conversation.reviews, timeline: conversation.timeline, linkedItems: conversation.linkedItems,
            checks: status.checks, files: status.files
        )
    }
}

extension DetailNode {
    /// What an issue answers to the pull-request-only status query: nothing.
    static var empty: DetailNode { DetailNode(
        __typename: nil, body: nil, headRefName: nil, baseRefName: nil, comments: nil, reviews: nil, timelineItems: nil,
        closingIssuesReferences: nil, closedByPullRequestsReferences: nil, changedFiles: nil, files: nil, commits: nil
    ) }
}
