import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!
/// `iso.date(from:)` for the timestamps in the fixtures.
private enum iso {
    static func date(from string: String) -> Date? { try? Date(string, strategy: .iso8601) }
}

/// Detail for one pull request or issue: two read-only GraphQL queries, captured from vapor/postgres-nio (public) on
/// 2026-11-03 with `gh api graphql`.
@Suite("Item detail")
struct ItemDetailTests {
    let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "prokopsimek"),
                          sources: [.repository(fullName: "vapor/postgres-nio")])

    /// The conversation query names `timelineItems`, the status query `statusCheckRollup`.
    static let conversation = "timelineItems"
    static let status = "statusCheckRollup"

    private func item(_ kind: ItemKind, _ number: Int, repo: String = "vapor/postgres-nio") -> WorkItem {
        WorkItem(accountID: account.id, kind: kind, repoFullName: repo, number: number, title: "Item \(number)",
                 url: URL(string: "https://github.com/\(repo)/\(kind == .pullRequest ? "pull" : "issues")/\(number)")!,
                 author: UserRef(login: "ptoffy"), createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 1))
    }

    private func detail(_ item: WorkItem, _ routes: [(String, StubTransport.Response)]) async throws -> (ItemDetail, RoutingTransport) {
        let transport = RoutingTransport(routes)
        let detail = try #require(await GitHubProvider(transport: transport).itemDetail(account: account, token: "t", item: item))
        return (detail, transport)
    }

    private func capturedPullRequest() throws -> [(String, StubTransport.Response)] {
        [
            (Self.status, .json(try Fixtures.data("graphql_item_detail_pull_request_status.json"))),
            (Self.conversation, .json(try Fixtures.data("graphql_item_detail_pull_request.json"))),
        ]
    }

    @Test("asks for one item by repository and number, read-only, in two queries")
    func queries() async throws {
        let (_, transport) = try await detail(item(.pullRequest, 686), try capturedPullRequest())

        let queries = await transport.queries
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { $0.contains("repository(owner: $owner, name: $name)") && $0.contains("issueOrPullRequest(number: 686)") })
        #expect(queries.allSatisfy { !$0.contains("mutation") })
        #expect(await transport.variables.allSatisfy { $0 == ["owner": "vapor", "name": "postgres-nio"] })
        let conversation = try #require(queries.first { $0.contains(Self.conversation) })
        #expect(conversation.contains("comments(last: 20)"))
        #expect(conversation.contains("reviews(last: 10)"))
        #expect(conversation.contains("timelineItems(last: 30"))
        let status = try #require(queries.first { $0.contains(Self.status) })
        #expect(status.contains("files(first: 100)"))
        #expect(status.contains("commits(last: 1)"))
    }

    @Test("maps the captured pull request: body, branches, conversation and timeline")
    func pullRequestConversation() async throws {
        let item = item(.pullRequest, 686)
        let (detail, _) = try await detail(item, try capturedPullRequest())

        #expect(detail.itemID == item.id)
        #expect(detail.itemUpdatedAt == item.updatedAt)
        #expect(try detail.body.get().hasPrefix("Fix for #679"))
        #expect(try detail.branches.get() == Branches(head: "max-connection-lifetime", base: "main"))

        let comments = try detail.comments.get()
        #expect(comments.map(\.author.login) == ["codecov"])
        #expect(comments.first?.url == URL(string: "https://github.com/vapor/postgres-nio/pull/686#issuecomment-5868273241"))
        #expect(comments.first?.createdAt == iso.date(from: "2026-09-28T10:39:26Z"))
        #expect(comments.first?.body.contains("<details>") == true)

        let reviews = try detail.reviews.get()
        #expect(reviews.map(\.author.login) == ["adam-fowler", "0xTim"])
        #expect(reviews.map(\.verdict) == [.commented, .changesRequested])
        #expect(reviews.last?.body == "Couple of edge cases to fix")
        #expect(reviews.last?.submittedAt == iso.date(from: "2026-11-03T02:01:46Z"))
        #expect(reviews.last?.url == URL(string: "https://github.com/vapor/postgres-nio/pull/686#pullrequestreview-5746136834"))

        let timeline = try detail.timeline.get()
        #expect(timeline.count == 14)
        #expect(timeline.first?.kind == .committed(sha: "ad2662d", message: "Add maximum connection lifetime timer"))
        #expect(timeline.first?.actor?.login == "ptoffy")
        #expect(timeline[1].kind == .labeled("ConnectionPool"))
        #expect(timeline.contains { $0.kind == .readyForReview && $0.actor?.login == "ptoffy" })
        #expect(timeline.filter { if case .reviewRequested = $0.kind { true } else { false } }.count == 2)
        #expect(timeline.last?.kind == .reviewed(.changesRequested))
        #expect(timeline.last?.actor?.login == "0xTim")
        #expect(try detail.linkedItems.get().isEmpty)
    }

    @Test("maps the captured checks by name, the failing one with its log, and the files")
    func pullRequestStatus() async throws {
        let (detail, _) = try await detail(item(.pullRequest, 686), try capturedPullRequest())

        let checks = try detail.checks.get()
        #expect(checks.count == 15)
        #expect(checks.filter { $0.state == .failed }.map(\.name) == ["linux-unit (swiftlang/swift:nightly-main-noble)"])
        #expect(checks.first { $0.state == .failed }?.url
            == URL(string: "https://github.com/vapor/postgres-nio/actions/runs/41424614799/job/125208084993"))
        #expect(checks.filter { $0.state == .skipped }.map(\.name) == ["submit-dependencies"])
        #expect(checks.filter { $0.state == .passed }.count == 13)

        let files = try detail.files.get()
        #expect(files.totalCount == 9)
        #expect(files.files.count == 9)
        #expect(files.files.first == ChangedFile(path: "Sources/ConnectionPoolModule/ConnectionPool.swift", additions: 9, deletions: 0))
    }

    @Test("an issue needs one query: comments, timeline and the pull requests that close it")
    func issue() async throws {
        let item = item(.issue, 499)
        let (detail, transport) = try await detail(item, [(Self.conversation, .json(try Fixtures.data("graphql_item_detail_issue.json")))])

        #expect(await transport.queries.count == 1)
        #expect(try detail.body.get().hasPrefix("### Describe the issue"))
        #expect(try detail.branches.get() == nil)
        #expect(try detail.comments.get().map(\.author.login) == ["vzsg", "MahdiBM", "MahdiBM", "fabianfett"])
        #expect(try detail.timeline.get().map(\.kind) == [.labeled("bug"), .commented, .commented, .commented, .commented])
        #expect(try detail.linkedItems.get() == [
            LinkedItem(kind: .pullRequest, repoFullName: "vapor/postgres-nio", number: 505, title: "Implement Basic `SimpleQuery` Handling ",
                       url: URL(string: "https://github.com/vapor/postgres-nio/pull/505")!, state: .open),
        ])
        #expect(try detail.reviews.get().isEmpty)
        #expect(try detail.checks.get().isEmpty)
        #expect(try detail.files.get().files.isEmpty)
    }

    @Test("the status query failing on its own leaves the conversation")
    func statusFailsAlone() async throws {
        let (detail, _) = try await detail(item(.pullRequest, 686), [
            (Self.status, .json(#"{"message":"Bad gateway"}"#, status: 502)),
            (Self.conversation, .json(try Fixtures.data("graphql_item_detail_pull_request.json"))),
        ])

        guard case .failure(.failed) = detail.checks, case .failure(.failed) = detail.files else {
            Issue.record("expected the checks and files to fail, got \(detail.checks) and \(detail.files)")
            return
        }
        #expect(try detail.reviews.get().count == 2)
    }

    @Test("a token that may not read the checks gets a missing permission there, not a broken Detail")
    func statusRefused() async throws {
        let refused = #"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by personal access token"}]}"#
        let (detail, _) = try await detail(item(.pullRequest, 686), [
            (Self.status, .json(refused)),
            (Self.conversation, .json(try Fixtures.data("graphql_item_detail_pull_request.json"))),
        ])

        #expect(detail.checks == .failure(.missingPermission))
        #expect(detail.files == .failure(.missingPermission))
        #expect(try detail.comments.get().count == 1)
    }

    @Test("a refused field fails only its own part")
    func partialRefusal() async throws {
        let answer = """
        {"data":{"repository":{"issueOrPullRequest":{"__typename":"PullRequest","changedFiles":1,\
        "files":{"totalCount":1,"nodes":[{"path":"README.md","additions":2,"deletions":1,"changeType":"MODIFIED"}]},\
        "commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":null}}]}}}},\
        "errors":[{"type":"FORBIDDEN","path":["repository","issueOrPullRequest","commits","nodes",0,"commit","statusCheckRollup"],\
        "message":"Resource not accessible by personal access token"}]}
        """
        let (detail, _) = try await detail(item(.pullRequest, 686), [
            (Self.status, .json(answer)),
            (Self.conversation, .json(try Fixtures.data("graphql_item_detail_pull_request.json"))),
        ])

        #expect(detail.checks == .failure(.missingPermission))
        #expect(try detail.files.get() == ChangedFiles(files: [ChangedFile(path: "README.md", additions: 2, deletions: 1)], totalCount: 1))
    }

    @Test("the conversation failing leaves the checks")
    func conversationFails() async throws {
        let (detail, _) = try await detail(item(.pullRequest, 686), [
            (Self.status, .json(try Fixtures.data("graphql_item_detail_pull_request_status.json"))),
            (Self.conversation, .json(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)),
        ])

        for failure in [detail.body.map { _ in () }, detail.comments.map { _ in () }, detail.timeline.map { _ in () }] {
            guard case .failure(.failed) = failure else {
                Issue.record("expected a passing failure, got \(failure)")
                continue
            }
        }
        #expect(try detail.checks.get().count == 15)
    }

    @Test("an item GitHub no longer finds fails every part")
    func notFound() async throws {
        let answer = #"{"data":{"repository":{"issueOrPullRequest":null}}}"#
        let (detail, _) = try await detail(item(.issue, 1), [(Self.conversation, .json(answer))])

        #expect(detail.body == .failure(.failed("vapor/postgres-nio#1 was not found.")))
    }

    @Test("an invalid repository name sends nothing")
    func invalidRepository() async throws {
        let (detail, transport) = try await detail(item(.issue, 1, repo: "not a repo"), [])

        #expect(await transport.queries.isEmpty)
        guard case .failure(.failed) = detail.body else {
            Issue.record("expected a failure, got \(detail.body)")
            return
        }
    }

    @Test("every event type of the timeline", arguments: [
        (#"{"__typename":"AssignedEvent","id":"AE_1","createdAt":"2026-11-01T10:00:00Z","actor":{"login":"jana"},"assignee":{"__typename":"User","login":"prokopsimek"}}"#,
         TimelineEvent.Kind.assigned("prokopsimek")),
        (#"{"__typename":"UnlabeledEvent","id":"UE_1","createdAt":"2026-11-01T10:00:00Z","actor":{"login":"jana"},"label":{"name":"wip"}}"#,
         .unlabeled("wip")),
        (#"{"__typename":"HeadRefForcePushedEvent","id":"HE_1","createdAt":"2026-11-01T10:00:00Z","actor":{"login":"jana"},"afterCommit":{"abbreviatedOid":"9f8e7d6"}}"#,
         .forcePushed(sha: "9f8e7d6")),
        (#"{"__typename":"ReviewRequestedEvent","id":"RE_1","createdAt":"2026-11-01T10:00:00Z","actor":{"login":"jana"},"requestedReviewer":{"__typename":"Team","slug":"platform"}}"#,
         .reviewRequested("platform")),
    ])
    func eventTypes(node: String, kind: TimelineEvent.Kind) async throws {
        let answer = """
        {"data":{"repository":{"issueOrPullRequest":{"__typename":"PullRequest","body":"","headRefName":"a","baseRefName":"main",\
        "comments":{"nodes":[]},"reviews":{"nodes":[]},"closingIssuesReferences":{"nodes":[]},"timelineItems":{"nodes":[\(node)]}}}}}
        """
        let status = #"{"data":{"repository":{"issueOrPullRequest":{"__typename":"PullRequest","changedFiles":0,"files":{"totalCount":0,"nodes":[]},"commits":{"nodes":[]}}}}}"#
        let (detail, _) = try await detail(item(.pullRequest, 1), [(Self.status, .json(status)), (Self.conversation, .json(answer))])

        let event = try #require(try detail.timeline.get().first)
        #expect(event.kind == kind)
        #expect(event.actor?.login == "jana")
        #expect(event.createdAt == iso.date(from: "2026-11-01T10:00:00Z"))
    }
}

/// Runs both detail queries against github.com, read-only:
///
///     GITWALL_GITHUB_TOKEN=… swift test --package-path Packages/GitwallGitHub --filter ItemDetailIntegration
///
/// `GITWALL_GITHUB_DETAIL=owner/repo#123` checks one more pull request, for example a private one with a fine-grained
/// token. `GITWALL_CAPTURE_DIR` saves the raw answers there, which is how the fixtures above were captured.
@Suite("Integration · item detail", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] != nil))
struct ItemDetailIntegrationTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Passes requests to GitHub and keeps each answer under the name of the part it fetched.
    actor Recorder: HTTPTransport {
        let directory: URL?
        let base: String
        init(directory: URL?, base: String) {
            self.directory = directory
            self.base = base
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await URLSessionTransport().send(request)
            if let directory {
                let query = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let suffix = query.contains(ItemDetailTests.status) ? "_status" : ""
                let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data),
                                                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try (pretty + Data("\n".utf8)).write(to: directory.appendingPathComponent("\(base)\(suffix).json"))
            }
            return (data, response)
        }
    }

    private func check(_ repo: String, _ number: Int, kind: ItemKind, capture name: String) async throws -> ItemDetail {
        let account = Account(kind: .github, baseURL: github, displayName: "GitHub", sources: [.repository(fullName: repo)])
        let item = WorkItem(accountID: account.id, kind: kind, repoFullName: repo, number: number, title: "", url: github,
                            author: UserRef(login: "ghost"), createdAt: Date(), updatedAt: Date())
        let recorder = Recorder(directory: environment["GITWALL_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }, base: name)
        let detail = try #require(await GitHubProvider(transport: recorder)
            .itemDetail(account: account, token: environment["GITWALL_GITHUB_TOKEN"] ?? "", item: item))
        func describe<Value>(_ section: DetailSection<Value>) -> String {
            switch section {
            case .success: "ok"
            case .failure(.missingPermission): "missing permission"
            case .failure(.failed(let message)): "failed: \(message)"
            }
        }
        print("""
        integration: \(repo)#\(number) body \(describe(detail.body)), comments \(describe(detail.comments)), \
        reviews \(describe(detail.reviews)), timeline \(describe(detail.timeline)), linked \(describe(detail.linkedItems)), \
        checks \(describe(detail.checks)), files \(describe(detail.files))
        """)
        return detail
    }

    @Test("a public pull request and issue read without a failure")
    func publicItems() async throws {
        let pull = try await check("vapor/postgres-nio", 686, kind: .pullRequest, capture: "graphql_item_detail_pull_request")
        #expect(pull.failures.isEmpty)
        let issue = try await check("vapor/postgres-nio", 499, kind: .issue, capture: "graphql_item_detail_issue")
        #expect(issue.failures.isEmpty)
    }

    @Test("GITWALL_GITHUB_DETAIL with this token", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITHUB_DETAIL"] != nil))
    func configuredItem() async throws {
        let reference = environment["GITWALL_GITHUB_DETAIL"] ?? ""
        let parts = reference.split(separator: "#")
        let number = try #require(parts.count == 2 ? Int(parts[1]) : nil, "Expected owner/repo#123")
        _ = try await check(String(parts[0]), number, kind: .pullRequest, capture: "configured_item_detail")
    }
}
