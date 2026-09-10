import Foundation
import GitwallCore
import Testing
@testable import GitwallAuth

@Suite("TokenReader")
struct TokenReaderTests {
    private let now = Date(timeIntervalSince1970: 1_757_484_000)
    private let account = UUID()

    @Test("returns nil for an unknown account")
    func unknownAccount() async throws {
        let reader = TokenReader(store: InMemoryTokenStore())
        #expect(try await reader.token(for: account) == nil)
    }

    @Test("returns the access token of a stored credential")
    func returnsAccessToken() async throws {
        let store = InMemoryTokenStore()
        try store.set(StoredToken(accessToken: "gho_abc", refreshToken: "ghr_x", obtainedAt: now), for: account)
        let reader = TokenReader(store: store)
        #expect(try await reader.token(for: account) == "gho_abc")
    }

    @Test("reflects later writes to the underlying store")
    func reflectsWrites() async throws {
        let store = InMemoryTokenStore()
        let reader = TokenReader(store: store)
        #expect(try await reader.token(for: account) == nil)
        try store.set(StoredToken(accessToken: "first", obtainedAt: now), for: account)
        #expect(try await reader.token(for: account) == "first")
        try store.removeToken(for: account)
        #expect(try await reader.token(for: account) == nil)
    }

    @Test("conforms to GitwallCore.TokenReading")
    func conformsToTokenReading() async throws {
        let store = InMemoryTokenStore()
        try store.set(StoredToken(accessToken: "t", obtainedAt: now), for: account)
        let reading: any TokenReading = TokenReader(store: store)
        #expect(try await reading.token(for: account) == "t")
    }

    @Test("propagates errors from the store")
    func propagatesErrors() async throws {
        struct Boom: Error, Equatable {}
        struct FailingStore: TokenStore {
            func token(for accountID: UUID) throws -> StoredToken? { throw Boom() }
            func set(_ token: StoredToken, for accountID: UUID) throws {}
            func removeToken(for accountID: UUID) throws {}
            func removeAll() throws {}
        }
        let reader = TokenReader(store: FailingStore())
        await #expect(throws: Boom.self) {
            try await reader.token(for: account)
        }
    }

    @Test("asTokenReading helper wraps the store")
    func asTokenReadingHelper() async throws {
        let store = InMemoryTokenStore()
        try store.set(StoredToken(accessToken: "helper", obtainedAt: now), for: account)
        let reading = store.asTokenReading()
        #expect(try await reading.token(for: account) == "helper")
    }
}
