import Foundation
import Testing
@testable import GitwallAuth

@Suite("StoredToken")
struct StoredTokenTests {
    private static let obtainedAt = Date(timeIntervalSince1970: 1_757_484_000) // 2025-09-10T06:00:00Z

    @Test("isExpiring is false when there is no expiry")
    func noExpiryNeverExpires() {
        let token = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: nil, obtainedAt: Self.obtainedAt)
        #expect(token.isExpiring(within: 3600, now: Self.obtainedAt) == false)
        #expect(token.isExpiring(within: 0, now: .distantFuture) == false)
    }

    @Test("isExpiring is true when expiry falls inside the window")
    func expiringInsideWindow() {
        let expiresAt = Self.obtainedAt.addingTimeInterval(600)
        let token = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        #expect(token.isExpiring(within: 3600, now: Self.obtainedAt) == true)
    }

    @Test("isExpiring is false when expiry is beyond the window")
    func notExpiringOutsideWindow() {
        let expiresAt = Self.obtainedAt.addingTimeInterval(7200)
        let token = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        #expect(token.isExpiring(within: 3600, now: Self.obtainedAt) == false)
    }

    @Test("isExpiring is true when the token has already expired")
    func alreadyExpired() {
        let expiresAt = Self.obtainedAt.addingTimeInterval(600)
        let token = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        #expect(token.isExpiring(within: 0, now: expiresAt.addingTimeInterval(1)) == true)
    }

    @Test("isExpiring treats the exact boundary as expiring")
    func boundaryIsExpiring() {
        let expiresAt = Self.obtainedAt.addingTimeInterval(3600)
        let token = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        #expect(token.isExpiring(within: 3600, now: Self.obtainedAt) == true)
    }

    @Test("encodes dates as ISO 8601 strings")
    func encodesISO8601() throws {
        let expiresAt = Self.obtainedAt.addingTimeInterval(3600)
        let token = StoredToken(accessToken: "gho_abc", refreshToken: "ghr_def", expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        let data = try StoredToken.encode(token)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"accessToken\""))
        #expect(json.contains("gho_abc"))
        #expect(json.contains("ghr_def"))
        #expect(json.contains("2025-09-10T06:00:00"))
        #expect(json.contains("2025-09-10T07:00:00"))
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let expiresAt = Self.obtainedAt.addingTimeInterval(3600)
        let token = StoredToken(accessToken: "gho_abc", refreshToken: "ghr_def", expiresAt: expiresAt, obtainedAt: Self.obtainedAt)
        let decoded = try StoredToken.decode(from: StoredToken.encode(token))
        #expect(decoded == token)
    }

    @Test("round-trips with optional fields absent")
    func roundTripWithoutOptionals() throws {
        let token = StoredToken(accessToken: "glpat-xyz", refreshToken: nil, expiresAt: nil, obtainedAt: Self.obtainedAt)
        let decoded = try StoredToken.decode(from: StoredToken.encode(token))
        #expect(decoded == token)
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiresAt == nil)
    }

    @Test("decodes ISO 8601 without fractional seconds")
    func decodesPlainISO8601() throws {
        let json = """
        {"accessToken":"t","obtainedAt":"2025-09-10T06:00:00Z"}
        """
        let decoded = try StoredToken.decode(from: Data(json.utf8))
        #expect(decoded.accessToken == "t")
        #expect(decoded.obtainedAt == Self.obtainedAt)
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiresAt == nil)
    }

    @Test("is Hashable")
    func hashable() {
        let a = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: nil, obtainedAt: Self.obtainedAt)
        let b = StoredToken(accessToken: "a", refreshToken: nil, expiresAt: nil, obtainedAt: Self.obtainedAt)
        let c = StoredToken(accessToken: "c", refreshToken: nil, expiresAt: nil, obtainedAt: Self.obtainedAt)
        #expect(Set([a, b, c]).count == 2)
    }
}
