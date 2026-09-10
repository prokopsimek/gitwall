import Foundation
import os

/// A ``TokenStore`` that keeps tokens in process memory. For tests and SwiftUI previews only.
public final class InMemoryTokenStore: TokenStore {
    // `OSAllocatedUnfairLock` owns the mutable dictionary, which is what makes this class
    // `Sendable` without `@unchecked`: all access goes through `withLock`.
    private let storage: OSAllocatedUnfairLock<[UUID: StoredToken]>

    public init(tokens: [UUID: StoredToken] = [:]) {
        storage = OSAllocatedUnfairLock(initialState: tokens)
    }

    public func token(for accountID: UUID) throws -> StoredToken? {
        storage.withLock { $0[accountID] }
    }

    public func set(_ token: StoredToken, for accountID: UUID) throws {
        storage.withLock { $0[accountID] = token }
    }

    public func removeToken(for accountID: UUID) throws {
        storage.withLock { _ = $0.removeValue(forKey: accountID) }
    }

    public func removeAll() throws {
        storage.withLock { $0.removeAll() }
    }
}
