import Foundation

/// Synchronous, per-account credential storage.
///
/// Implementations must be safe to call from any thread. Production code uses
/// ``KeychainTokenStore``; tests and previews use ``InMemoryTokenStore``.
public protocol TokenStore: Sendable {
    /// The token stored for `accountID`, or `nil` when none exists.
    func token(for accountID: UUID) throws -> StoredToken?
    /// Stores `token` for `accountID`, replacing any previous value.
    func set(_ token: StoredToken, for accountID: UUID) throws
    /// Removes the token for `accountID`. Removing a missing token is not an error.
    func removeToken(for accountID: UUID) throws
    /// Removes every token this store owns.
    func removeAll() throws
}
