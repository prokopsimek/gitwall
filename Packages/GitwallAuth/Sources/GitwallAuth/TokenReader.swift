import Foundation
import GitwallCore

/// Adapts any ``TokenStore`` to GitwallCore's read-only ``TokenReading`` so the sync
/// engine can fetch bearer tokens without depending on this package's write API.
public struct TokenReader: TokenReading {
    private let store: any TokenStore

    public init(store: any TokenStore) {
        self.store = store
    }

    /// The access token for `accountID`, or `nil` when no credential is stored.
    public func token(for accountID: UUID) async throws -> String? {
        try store.token(for: accountID)?.accessToken
    }
}

extension TokenStore {
    /// This store viewed through GitwallCore's ``TokenReading`` protocol.
    public func asTokenReading() -> TokenReader {
        TokenReader(store: self)
    }
}
