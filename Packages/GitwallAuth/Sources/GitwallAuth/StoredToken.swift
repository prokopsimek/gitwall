import Foundation
import GitwallCore

/// A credential set for one account as persisted in the Keychain.
///
/// Serialised as JSON with ISO 8601 dates via ``SnapshotCoding`` so the on-disk
/// format matches the rest of Gitwall.
public struct StoredToken: Codable, Hashable, Sendable {
    /// Bearer token sent to the provider API.
    public var accessToken: String
    /// Refresh token for OAuth flows; `nil` for personal access tokens.
    public var refreshToken: String?
    /// When `accessToken` stops working; `nil` for non-expiring tokens.
    public var expiresAt: Date?
    /// When the credential was issued or last refreshed.
    public var obtainedAt: Date

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, obtainedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.obtainedAt = obtainedAt
    }

    /// `true` when the token expires at or before `now + interval`. Tokens without an expiry never expire.
    public func isExpiring(within interval: TimeInterval, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(interval)
    }

    /// JSON with ISO 8601 dates, stable key order.
    public static func encode(_ token: StoredToken) throws -> Data {
        try SnapshotCoding.encode(token)
    }

    /// Inverse of ``encode(_:)``; accepts ISO 8601 with or without fractional seconds.
    public static func decode(from data: Data) throws -> StoredToken {
        try SnapshotCoding.decode(StoredToken.self, from: data)
    }
}
