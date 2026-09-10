import Foundation
import Testing
@testable import GitwallAuth

@Suite("InMemoryTokenStore")
struct InMemoryTokenStoreTests {
    private let now = Date(timeIntervalSince1970: 1_757_484_000)
    private let account = UUID()
    private let otherAccount = UUID()

    private func token(_ access: String) -> StoredToken {
        StoredToken(accessToken: access, refreshToken: nil, expiresAt: nil, obtainedAt: now)
    }

    @Test("returns nil for an unknown account")
    func unknownAccountIsNil() throws {
        let store = InMemoryTokenStore()
        #expect(try store.token(for: account) == nil)
    }

    @Test("set then get returns the stored token")
    func setThenGet() throws {
        let store = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        #expect(try store.token(for: account) == token("one"))
    }

    @Test("set overwrites an existing token")
    func overwrite() throws {
        let store = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: account)
        #expect(try store.token(for: account) == token("two"))
    }

    @Test("tokens are isolated per account")
    func isolationBetweenAccounts() throws {
        let store = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        #expect(try store.token(for: account) == token("one"))
        #expect(try store.token(for: otherAccount) == token("two"))
    }

    @Test("removeToken deletes only that account")
    func removeToken() throws {
        let store = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        try store.removeToken(for: account)
        #expect(try store.token(for: account) == nil)
        #expect(try store.token(for: otherAccount) == token("two"))
    }

    @Test("removeToken for an unknown account does not throw")
    func removeUnknownIsNoop() throws {
        let store = InMemoryTokenStore()
        try store.removeToken(for: account)
        #expect(try store.token(for: account) == nil)
    }

    @Test("removeAll empties the store")
    func removeAll() throws {
        let store = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        try store.removeAll()
        #expect(try store.token(for: account) == nil)
        #expect(try store.token(for: otherAccount) == nil)
    }

    @Test("can be seeded through the initialiser")
    func seeded() throws {
        let store = InMemoryTokenStore(tokens: [account: token("seed")])
        #expect(try store.token(for: account) == token("seed"))
    }

    @Test("is usable as an existential TokenStore")
    func existential() throws {
        let store: any TokenStore = InMemoryTokenStore()
        try store.set(token("one"), for: account)
        #expect(try store.token(for: account) == token("one"))
    }

    @Test("survives concurrent writes from multiple tasks")
    func concurrentWrites() async throws {
        let store = InMemoryTokenStore()
        let ids = (0..<50).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    try? store.set(StoredToken(accessToken: "t\(index)", obtainedAt: now), for: id)
                }
            }
        }
        for (index, id) in ids.enumerated() {
            #expect(try store.token(for: id)?.accessToken == "t\(index)")
        }
    }
}
