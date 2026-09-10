import Foundation
import Testing
@testable import GitwallCore

@Suite("FilterEngine")
struct FilterEngineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let github = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub", me: UserRef(login: "me"))
    let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", me: UserRef(login: "me"))

    private func item(
        _ number: Int,
        account: Account? = nil,
        kind: ItemKind = .pullRequest,
        repo: String = "acme/app",
        title: String = "Change",
        author: String = "someone",
        ageHours: Double = 1,
        createdDaysAgo: Double = 2,
        isDraft: Bool = false,
        labels: [String] = [],
        assignees: [String] = [],
        requestedReviewers: [String] = [],
        reviewState: ReviewState? = ReviewState.none,
        ciState: CIState? = CIState.none,
        mergeState: MergeState? = .unknown,
        milestone: String? = nil
    ) -> WorkItem {
        let account = account ?? github
        return WorkItem(
            accountID: account.id,
            kind: kind,
            repoFullName: repo,
            number: number,
            title: title,
            url: URL(string: "https://example.com/\(number)")!,
            author: UserRef(login: author),
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400),
            updatedAt: now.addingTimeInterval(-ageHours * 3_600),
            isDraft: isDraft,
            labels: labels.map { Label(name: $0) },
            assignees: assignees.map { UserRef(login: $0) },
            milestone: milestone,
            reviewState: kind == .pullRequest ? reviewState : nil,
            ciState: kind == .pullRequest ? ciState : nil,
            mergeState: kind == .pullRequest ? mergeState : nil,
            requestedReviewers: requestedReviewers.map { UserRef(login: $0) }
        )
    }

    private func run(_ preset: Preset, _ items: [WorkItem], accounts: [Account]? = nil) -> [Int] {
        FilterEngine.items(matching: preset, in: items, accounts: accounts ?? [github, gitlab], now: now).map(\.number)
    }

    @Test("keeps only the requested kinds")
    func kinds() {
        let items = [item(1, kind: .pullRequest), item(2, kind: .issue)]
        #expect(run(Preset(name: "PRs", kinds: [.pullRequest]), items) == [1])
        #expect(run(Preset(name: "Issues", kinds: [.issue]), items) == [2])
        #expect(run(Preset(name: "Both", kinds: [.pullRequest, .issue]), items) == [1, 2])
    }

    @Test("empty scopes mean every account, explicit scopes restrict to account and repositories")
    func scopes() {
        let items = [
            item(1, account: github, repo: "acme/app", ageHours: 1),
            item(2, account: github, repo: "acme/web", ageHours: 2),
            item(3, account: gitlab, repo: "acme/app", ageHours: 3),
        ]
        #expect(run(Preset(name: "All"), items) == [1, 2, 3])
        #expect(run(Preset(name: "GitHub", scopes: [PresetScope(accountID: github.id)]), items) == [1, 2])
        #expect(run(Preset(name: "One repo", scopes: [PresetScope(accountID: github.id, repositories: ["acme/web"])]), items) == [2])
        #expect(run(Preset(name: "Mixed", scopes: [
            PresetScope(accountID: github.id, repositories: ["acme/web"]),
            PresetScope(accountID: gitlab.id),
        ]), items) == [2, 3])
    }

    @Test("relations use the account identity and combine with OR")
    func relations() {
        let items = [
            item(1, author: "me"),
            item(2, requestedReviewers: ["me"]),
            item(3, assignees: ["me"]),
            item(4, author: "other"),
        ]
        #expect(run(Preset(name: "Mine", filter: ItemFilter(relations: [.authoredByMe])), items) == [1])
        #expect(run(Preset(name: "Review", filter: ItemFilter(relations: [.reviewRequestedFromMe])), items) == [2])
        #expect(run(Preset(name: "Assigned", filter: ItemFilter(relations: [.assignedToMe])), items) == [3])
        #expect(run(Preset(name: "Any of mine", filter: ItemFilter(relations: [.authoredByMe, .assignedToMe])), items) == [1, 3])
    }

    @Test("relation filters match logins case-insensitively and fail closed without an identity")
    func relationsIdentity() {
        let items = [item(1, author: "Me")]
        #expect(run(Preset(name: "Mine", filter: ItemFilter(relations: [.authoredByMe])), items) == [1])
        let anonymous = Account(id: github.id, kind: .github, baseURL: github.baseURL, displayName: "GitHub", me: nil)
        #expect(run(Preset(name: "Mine", filter: ItemFilter(relations: [.authoredByMe])), items, accounts: [anonymous]) == [])
    }

    @Test("drafts can be excluded")
    func drafts() {
        let items = [item(1, isDraft: true), item(2)]
        #expect(run(Preset(name: "With drafts"), items) == [1, 2])
        #expect(run(Preset(name: "No drafts", filter: ItemFilter(includeDrafts: false)), items) == [2])
    }

    @Test("labels: any-of includes, none-of excludes, case-insensitive")
    func labels() {
        let items = [item(1, labels: ["Bug"]), item(2, labels: ["feature"]), item(3, labels: ["bug", "wontfix"])]
        #expect(run(Preset(name: "Bugs", filter: ItemFilter(labelsAny: ["bug"])), items) == [1, 3])
        #expect(run(Preset(name: "Not wontfix", filter: ItemFilter(labelsNone: ["WONTFIX"])), items) == [1, 2])
        #expect(run(Preset(name: "Bugs not wontfix", filter: ItemFilter(labelsAny: ["bug"], labelsNone: ["wontfix"])), items) == [1])
    }

    @Test("review, CI and merge states restrict pull requests; issues are unaffected by them")
    func states() {
        let items = [
            item(1, reviewState: .approved, ciState: .success, mergeState: .clean),
            item(2, reviewState: .changesRequested, ciState: .failure, mergeState: .conflict),
            item(3, kind: .issue),
        ]
        let both: Set<ItemKind> = [.pullRequest, .issue]
        #expect(run(Preset(name: "Approved", kinds: both, filter: ItemFilter(reviewStates: [.approved])), items) == [1, 3])
        #expect(run(Preset(name: "Red CI", kinds: both, filter: ItemFilter(ciStates: [.failure])), items) == [2, 3])
        #expect(run(Preset(name: "Conflicts", kinds: [.pullRequest], filter: ItemFilter(mergeStates: [.conflict])), items) == [2])
    }

    @Test("updatedWithinDays drops stale items")
    func age() {
        let items = [item(1, ageHours: 5), item(2, ageHours: 24 * 10)]
        #expect(run(Preset(name: "Week", filter: ItemFilter(updatedWithinDays: 7)), items) == [1])
    }

    @Test("milestone and text search")
    func milestoneAndText() {
        let items = [
            item(1, title: "Fix login crash", milestone: "v1.0"),
            item(2, repo: "acme/login-service", title: "Refactor", milestone: "v1.1"),
            item(3, title: "Docs"),
        ]
        #expect(run(Preset(name: "v1.0", filter: ItemFilter(milestone: "v1.0")), items) == [1])
        #expect(run(Preset(name: "login", filter: ItemFilter(text: "LOGIN")), items) == [1, 2])
        #expect(run(Preset(name: "number", filter: ItemFilter(text: "#3")), items) == [3])
    }

    @Test("sort orders")
    func sorting() {
        let items = [
            item(1, ageHours: 3, createdDaysAgo: 1),
            item(2, ageHours: 1, createdDaysAgo: 5),
            item(3, ageHours: 2, createdDaysAgo: 3),
        ]
        #expect(run(Preset(name: "Activity", sort: .lastActivity), items) == [2, 3, 1])
        #expect(run(Preset(name: "Newest", sort: .newestCreated), items) == [1, 3, 2])
        #expect(run(Preset(name: "Oldest", sort: .oldestCreated), items) == [2, 3, 1])
    }

    @Test("counts per preset for the menu bar badge")
    func counts() {
        let items = [item(1, author: "me"), item(2)]
        let mine = Preset(name: "Mine", filter: ItemFilter(relations: [.authoredByMe]), showCountInMenuBar: true)
        let all = Preset(name: "All")
        let counts = FilterEngine.counts(for: [mine, all], in: items, accounts: [github], now: now)
        #expect(counts[mine.id] == 1)
        #expect(counts[all.id] == 2)
    }
}
