import Foundation

/// Read-only access to account tokens, implemented by the Keychain store in the app.
public protocol TokenReading: Sendable {
    func token(for accountID: UUID) async throws -> String?
}
