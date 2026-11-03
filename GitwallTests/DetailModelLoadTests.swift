import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Holds the provider's answer until the test lets it go, so a test can look at Detail while a fetch is running.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [String] = []

    func pass(_ itemID: String) async {
        calls.append(itemID)
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// A GitHub that lists `items` and answers Detail with `detail(item)` once the gate opens. Never touches the network.
private struct StubProvider: GitProvider {
    let items: [WorkItem]
    let gate: Gate
    let detail: @Sendable (WorkItem) -> ItemDetail

    var kind: ProviderKind { .github }
    var capabilities: ProviderCapabilities {
        ProviderCapabilities(pullRequestTerm: "Pull request", pullRequestAbbreviation: "PR", supportsOrganizationSources: true,
                             supportsGroupSources: false, resolvesTeamReviewRequests: false, hostName: "GitHub",
                             fetchesItemDetail: true)
    }
    func verify(baseURL: URL, token: String) async throws -> UserRef { UserRef(login: "prokop") }
    func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
    func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
    func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] { items }
    func itemDetail(account: Account, token: String, item: WorkItem) async -> ItemDetail? {
        await gate.pass(item.id)
        return detail(item)
    }
}

/// Detail with a real (stubbed) account: when an item counts as seen, which links open, and what a preset explains.
@Suite("Detail model · loading")
@MainActor
struct DetailModelLoadTests {
    private let sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitwall-detail-load-\(UUID().uuidString)")
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub (prokop)",
                                  me: UserRef(login: "prokop"), sources: [.repository(fullName: "acme/app")])

    private func items() -> [WorkItem] {
        (1...2).map { number in
            WorkItem(accountID: account.id, kind: .pullRequest, repoFullName: "acme/app", number: number, title: "Change \(number)",
                     url: URL(string: "https://github.com/acme/app/pull/\(number)")!, author: UserRef(login: "jana"),
                     createdAt: fetchedAt.addingTimeInterval(-3600), updatedAt: fetchedAt.addingTimeInterval(-60))
        }
    }

    private func environment(
        gate: Gate,
        timeline: DetailSection<[TimelineEvent]> = .success([])
    ) async throws -> AppEnvironment {
        let config = AppConfig().adding(account, pullRequestTerm: "Pull request")
        try ConfigStore(directoryURL: sandbox).save(config)
        let fetchedAt = fetchedAt
        let provider = StubProvider(items: items(), gate: gate) { item in
            ItemDetail(itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: fetchedAt, timeline: timeline)
        }
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "t", obtainedAt: Date())]),
            sandbox: sandbox,
            providers: [.github: provider]
        )
        environment.start()
        await environment.refresh()
        #expect(environment.snapshot?.items.count == 2)
        return environment
    }

    /// Polls `condition` every 20 ms for at most two seconds.
    private func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("an item counts as seen when its detail has loaded, at the time it was fetched, not when it was clicked")
    func seenAfterLoad() async throws {
        let gate = Gate()
        let environment = try await environment(gate: gate)
        let model = DetailModel(environment: environment)
        let item = try #require(environment.snapshot?.items.first)

        model.show(item.id)
        #expect(try await eventually { await gate.calls == [item.id] })
        #expect(environment.details.lastSeen(item.id) == nil, "still loading")

        await gate.open()
        #expect(try await eventually { environment.details.lastSeen(item.id) != nil })
        #expect(environment.details.lastSeen(item.id) == fetchedAt)
    }

    @Test("an item left before its detail arrives is not seen")
    func leftBeforeLoad() async throws {
        let gate = Gate()
        let environment = try await environment(gate: gate)
        let model = DetailModel(environment: environment, seenDelay: .milliseconds(100))
        let first = try #require(environment.snapshot?.items.first)
        let second = try #require(environment.snapshot?.items.last)

        model.show(first.id)
        #expect(try await eventually { await gate.calls == [first.id] })
        model.select(second.id)
        await gate.open()

        #expect(try await eventually { model.selectedRemote != nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(environment.details.lastSeen(first.id) == nil)
        #expect(environment.details.lastSeen(second.id) == fetchedAt)
    }

    @Test("an item whose timeline did not load is not seen, so What's new keeps its events")
    func failedTimelineNotSeen() async throws {
        let gate = Gate()
        await gate.open()
        let environment = try await environment(gate: gate, timeline: .failure(.failed("Bad gateway")))
        let model = DetailModel(environment: environment, seenDelay: .milliseconds(100))
        let item = try #require(environment.snapshot?.items.first)

        model.show(item.id)
        #expect(try await eventually { model.selectedRemote != nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(environment.details.lastSeen(item.id) == nil)
    }

    @Test("only web links open; javascript:, file: and app schemes are ignored")
    func onlyWebLinksOpen() async throws {
        let environment = try await environment(gate: Gate())
        var opened: [URL] = []
        let model = DetailModel(environment: environment, openURL: { opened.append($0) })
        let item = try #require(environment.snapshot?.items.first)

        for link in ["javascript:alert(1)", "file:///etc/passwd", "x-apple.systempreferences:", "https://github.com/acme/app/pull/1"] {
            model.open(try #require(URL(string: link)), about: item)
        }

        #expect(opened == [URL(string: "https://github.com/acme/app/pull/1")!])
    }

    @Test("a credential change forgets the details fetched with the old one")
    func credentialChangeForgets() async throws {
        let gate = Gate()
        await gate.open()
        let environment = try await environment(gate: gate)
        let item = try #require(environment.snapshot?.items.first)

        _ = await environment.details.load(item, account: account, forceRefresh: false)
        #expect(environment.details.cachedDetail(for: item) != nil)
        try await environment.replaceCredential(for: account, credential: StoredToken(accessToken: "new", obtainedAt: Date()))

        #expect(environment.details.cachedDetail(for: item) == nil)
    }
}
