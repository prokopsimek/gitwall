import Foundation
import GitwallAuth
import GitwallCore
import os
import Testing

@Suite("TokenRefresher")
struct TokenRefresherTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Scripted refresh outcomes; counts calls so tests can prove there was a single in-flight refresh.
    final class ScriptedFlow: RefreshableFlow, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (calls: 0, results: [Result<StoredToken, RefreshError>]()))
        var delay: TimeInterval = 0

        init(_ results: [Result<StoredToken, RefreshError>]) {
            lock.withLock { $0.results = results }
        }

        var calls: Int { lock.withLock { $0.calls } }

        func refresh(_ token: StoredToken) async throws -> StoredToken {
            let result: Result<StoredToken, RefreshError> = lock.withLock { state in
                state.calls += 1
                return state.results.isEmpty ? .failure(.network("unscripted")) : state.results.removeFirst()
            }
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            return try result.get()
        }
    }

    func oauthAccount() -> Account {
        Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", authMethod: .oauth(clientID: "app"))
    }

    func patAccount() -> Account {
        Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")
    }

    @Test("returns the stored token untouched when it is not close to expiry")
    func fresh() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc", refreshToken: "ref", expiresAt: now.addingTimeInterval(3600), obtainedAt: now)])
        let flow = ScriptedFlow([])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        #expect(try await refresher.validToken(for: account) == "acc")
        #expect(flow.calls == 0)
    }

    @Test("refreshes proactively inside the leeway and persists the rotated pair atomically")
    func proactive() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now.addingTimeInterval(300), obtainedAt: now)])
        let rotated = StoredToken(accessToken: "acc2", refreshToken: "ref2", expiresAt: now.addingTimeInterval(7200), obtainedAt: now)
        let flow = ScriptedFlow([.success(rotated)])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, leeway: 600, now: { now })

        #expect(try await refresher.validToken(for: account) == "acc2")
        #expect(try store.token(for: account.id) == rotated)
        #expect(flow.calls == 1)
    }

    @Test("personal access tokens are never refreshed, even when expiring")
    func pat() async throws {
        let account = patAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "ghp", expiresAt: now.addingTimeInterval(60), obtainedAt: now)])
        let flow = ScriptedFlow([])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        #expect(try await refresher.validToken(for: account) == "ghp")
        #expect(try await refresher.tokenAfterUnauthorized(for: account) == nil)
        #expect(flow.calls == 0)
    }

    @Test("concurrent callers share one in-flight refresh")
    func singleFlight() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now, obtainedAt: now)])
        let flow = ScriptedFlow([.success(StoredToken(accessToken: "acc2", refreshToken: "ref2", expiresAt: now.addingTimeInterval(7200), obtainedAt: now))])
        flow.delay = 0.2
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        async let first = refresher.validToken(for: account)
        async let second = refresher.validToken(for: account)
        let results = try await [first, second]

        #expect(results == ["acc2", "acc2"])
        #expect(flow.calls == 1)
    }

    @Test("invalid_grant marks the account for re-authentication and stops retrying until a new token is stored")
    func invalidGrant() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now, obtainedAt: now)])
        let flow = ScriptedFlow([.failure(.invalidGrant), .success(StoredToken(accessToken: "never", obtainedAt: now))])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        #expect(try await refresher.validToken(for: account) == nil)
        #expect(try await refresher.validToken(for: account) == nil)
        #expect(try await refresher.tokenAfterUnauthorized(for: account) == nil)
        #expect(flow.calls == 1)
        // The old credential stays in place so the user can still see what account it was.
        #expect(try store.token(for: account.id)?.accessToken == "acc1")

        // Signing in again stores a fresh credential; the refresher forgets the failure on its own.
        try store.set(StoredToken(accessToken: "acc9", refreshToken: "ref9", expiresAt: now.addingTimeInterval(7200), obtainedAt: now.addingTimeInterval(1)), for: account.id)
        #expect(try await refresher.validToken(for: account) == "acc9")
    }

    @Test("a network failure during proactive refresh keeps the current token")
    func networkKeepsToken() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now.addingTimeInterval(120), obtainedAt: now)])
        let flow = ScriptedFlow([.failure(.network("offline"))])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        #expect(try await refresher.validToken(for: account) == "acc1")
        #expect(try store.token(for: account.id)?.accessToken == "acc1")
    }

    @Test("after a 401 the refresher retries once and surfaces network errors instead of forcing re-auth")
    func afterUnauthorized() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now.addingTimeInterval(3600), obtainedAt: now)])
        let flow = ScriptedFlow([.success(StoredToken(accessToken: "acc2", refreshToken: "ref2", expiresAt: now.addingTimeInterval(7200), obtainedAt: now)), .failure(.network("offline"))])
        let refresher = TokenRefresher(store: store, flows: { _ in flow }, now: { now })

        #expect(try await refresher.tokenAfterUnauthorized(for: account) == "acc2")
        await #expect(throws: RefreshError.network("offline")) { try await refresher.tokenAfterUnauthorized(for: account) }
    }

    @Test("accounts without a flow (no client registered) behave like PAT accounts")
    func noFlow() async throws {
        let account = oauthAccount()
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now, obtainedAt: now)])
        let refresher = TokenRefresher(store: store, flows: { _ in nil }, now: { now })
        #expect(try await refresher.validToken(for: account) == "acc1")
        #expect(try await refresher.tokenAfterUnauthorized(for: account) == nil)
    }
}

@Suite("RefreshingTokenReader")
struct RefreshingTokenReaderTests {
    @Test("resolves the account for the sync engine and falls back to nil for unknown ids")
    func reader() async throws {
        let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")
        let store = InMemoryTokenStore(tokens: [account.id: StoredToken(accessToken: "ghp", obtainedAt: Date())])
        let refresher = TokenRefresher(store: store, flows: { _ in nil })
        let reader = RefreshingTokenReader(refresher: refresher, accounts: { [account] })
        #expect(try await reader.token(for: account.id) == "ghp")
        #expect(try await reader.token(for: UUID()) == nil)
        #expect(try await reader.tokenAfterUnauthorized(for: account.id) == nil)
    }
}
