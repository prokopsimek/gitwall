import Foundation

/// Read-only access to account tokens, implemented by the Keychain store in the app.
public protocol TokenReading: Sendable {
    func token(for accountID: UUID) async throws -> String?

    /// A token to retry with after the provider rejected the previous one, or `nil` when only a new sign-in helps.
    /// Implementations that cannot refresh (personal access tokens) keep the default and give up immediately.
    func tokenAfterUnauthorized(for accountID: UUID) async throws -> String?
}

extension TokenReading {
    public func tokenAfterUnauthorized(for accountID: UUID) async throws -> String? { nil }
}
