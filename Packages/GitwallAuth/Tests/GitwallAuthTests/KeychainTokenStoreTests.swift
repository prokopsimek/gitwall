import Foundation
import Security
import Testing
@testable import GitwallAuth

@Suite("KeychainTokenStore configuration")
struct KeychainTokenStoreConfigurationTests {
    @Test("uses the Gitwall token service by default")
    func defaultService() {
        #expect(KeychainTokenStore().service == "cz.prokopsimek.gitwall.tokens")
        #expect(KeychainTokenStore.defaultService == "cz.prokopsimek.gitwall.tokens")
    }

    @Test("accepts a custom service name")
    func customService() {
        #expect(KeychainTokenStore(service: "cz.example.test").service == "cz.example.test")
    }

    @Test("is usable as an existential TokenStore")
    func existential() {
        let store: any TokenStore = KeychainTokenStore(service: "cz.example.test")
        #expect((store as? KeychainTokenStore)?.service == "cz.example.test")
    }
}

/// Talks to the real data-protection Keychain. Opt in with `GITWALL_KEYCHAIN_TESTS=1 swift test`.
///
/// The unsigned `swift test` runner has no application-identifier entitlement, so on most
/// machines these fail with `errSecMissingEntitlement` (-34018); run them from a signed
/// host (Xcode test target) to get real coverage.
@Suite(
    "KeychainTokenStore (integration)",
    .enabled(if: ProcessInfo.processInfo.environment["GITWALL_KEYCHAIN_TESTS"] == "1"),
    .serialized
)
struct KeychainTokenStoreIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_757_484_000)

    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "cz.prokopsimek.gitwall.tests.\(UUID().uuidString)")
    }

    private func token(_ access: String, refresh: String? = nil) -> StoredToken {
        StoredToken(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(3600), obtainedAt: now)
    }

    @Test("returns nil for an unknown account")
    func unknownAccount() throws {
        let store = makeStore()
        defer { try? store.removeAll() }
        #expect(try store.token(for: UUID()) == nil)
    }

    @Test("set then get round-trips the token")
    func setThenGet() throws {
        let store = makeStore()
        defer { try? store.removeAll() }
        let account = UUID()
        try store.set(token("gho_abc", refresh: "ghr_def"), for: account)
        #expect(try store.token(for: account) == token("gho_abc", refresh: "ghr_def"))
    }

    @Test("set upserts an existing item")
    func upsert() throws {
        let store = makeStore()
        defer { try? store.removeAll() }
        let account = UUID()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: account)
        #expect(try store.token(for: account) == token("two"))
    }

    @Test("tokens are isolated per account and per service")
    func isolation() throws {
        let store = makeStore()
        let otherStore = makeStore()
        defer {
            try? store.removeAll()
            try? otherStore.removeAll()
        }
        let account = UUID()
        let otherAccount = UUID()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        #expect(try store.token(for: account) == token("one"))
        #expect(try store.token(for: otherAccount) == token("two"))
        #expect(try otherStore.token(for: account) == nil)
    }

    @Test("removeToken deletes only that account and tolerates missing items")
    func removeToken() throws {
        let store = makeStore()
        defer { try? store.removeAll() }
        let account = UUID()
        let otherAccount = UUID()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        try store.removeToken(for: account)
        try store.removeToken(for: account)
        #expect(try store.token(for: account) == nil)
        #expect(try store.token(for: otherAccount) == token("two"))
    }

    @Test("removeAll deletes every item of the service and nothing else")
    func removeAll() throws {
        let store = makeStore()
        let otherStore = makeStore()
        defer {
            try? store.removeAll()
            try? otherStore.removeAll()
        }
        let account = UUID()
        let otherAccount = UUID()
        try store.set(token("one"), for: account)
        try store.set(token("two"), for: otherAccount)
        try otherStore.set(token("keep"), for: account)
        try store.removeAll()
        try store.removeAll()
        #expect(try store.token(for: account) == nil)
        #expect(try store.token(for: otherAccount) == nil)
        #expect(try otherStore.token(for: account) == token("keep"))
    }

    @Test("corrupt item data surfaces as KeychainError.decoding")
    func corruptData() throws {
        let store = makeStore()
        defer { try? store.removeAll() }
        let account = UUID()
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: store.service,
            kSecAttrAccount: account.uuidString,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: Data("not json".utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        try #require(status == errSecSuccess, "SecItemAdd failed: \(status)")
        #expect(throws: KeychainError.decoding) {
            try store.token(for: account)
        }
    }
}
