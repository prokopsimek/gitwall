import Foundation
import GitwallCore

/// Keeps OAuth access tokens valid without the user noticing.
///
/// Proactive: a token closer than `leeway` to its expiry is refreshed before it is handed out. Reactive: after a 401 the
/// sync engine asks ``tokenAfterUnauthorized(for:)`` for one more attempt. Concurrent callers share a single in-flight
/// refresh per account, so a rotated refresh token is never used twice. After `invalid_grant` the account is remembered
/// as needing a new sign-in until a different credential appears in the store.
public actor TokenRefresher {
    public typealias FlowProvider = @Sendable (Account) -> (any RefreshableFlow)?

    private let store: any TokenStore
    private let flows: FlowProvider
    private let leeway: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: [UUID: Task<StoredToken, Error>] = [:]
    /// `obtainedAt` of the credential whose refresh failed with `invalid_grant`, per account.
    private var reauthRequired: [UUID: Date] = [:]

    public init(store: any TokenStore, flows: @escaping FlowProvider, leeway: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.flows = flows
        self.leeway = leeway
        self.now = now
    }

    /// The access token to use for the next request, refreshed first when it is about to expire.
    /// `nil` when nothing is stored or the account needs a new sign-in.
    public func validToken(for account: Account) async throws -> String? {
        guard let stored = try store.token(for: account.id) else { return nil }
        guard let flow = flows(account), stored.refreshToken != nil else { return stored.accessToken }
        if needsReauth(account.id, stored) { return nil }
        guard stored.isExpiring(within: leeway, now: now()) else { return stored.accessToken }
        do {
            return try await refresh(stored, for: account, using: flow).accessToken
        } catch RefreshError.invalidGrant {
            reauthRequired[account.id] = stored.obtainedAt
            return nil
        } catch is RefreshError {
            // Transient: keep using what we have; the next sync tries again.
            return stored.accessToken
        }
    }

    /// Called after the provider rejected the token. Returns a fresh token to retry with, `nil` when only a new
    /// sign-in can help, and throws for transient failures so the account shows an error rather than "sign in again".
    public func tokenAfterUnauthorized(for account: Account) async throws -> String? {
        guard let stored = try store.token(for: account.id), let flow = flows(account), stored.refreshToken != nil else { return nil }
        if needsReauth(account.id, stored) { return nil }
        do {
            return try await refresh(stored, for: account, using: flow).accessToken
        } catch RefreshError.invalidGrant {
            reauthRequired[account.id] = stored.obtainedAt
            return nil
        }
    }

    // MARK: - Private

    private func needsReauth(_ accountID: UUID, _ stored: StoredToken) -> Bool {
        guard let failedAt = reauthRequired[accountID] else { return false }
        if failedAt == stored.obtainedAt { return true }
        // A different credential was stored since the failure: the user signed in again.
        reauthRequired[accountID] = nil
        return false
    }

    private func refresh(_ stored: StoredToken, for account: Account, using flow: any RefreshableFlow) async throws -> StoredToken {
        if let running = inFlight[account.id] {
            return try await running.value
        }
        let store = self.store
        let task = Task<StoredToken, Error> {
            let rotated = try await flow.refresh(stored)
            try store.set(rotated, for: account.id)
            return rotated
        }
        inFlight[account.id] = task
        defer { inFlight[account.id] = nil }
        return try await task.value
    }
}

/// `TokenReading` for the sync engine: resolves accounts and lets the refresher keep tokens valid.
public struct RefreshingTokenReader: TokenReading {
    private let refresher: TokenRefresher
    private let accounts: @Sendable () throws -> [Account]

    public init(refresher: TokenRefresher, accounts: @escaping @Sendable () throws -> [Account]) {
        self.refresher = refresher
        self.accounts = accounts
    }

    public func token(for accountID: UUID) async throws -> String? {
        guard let account = try accounts().first(where: { $0.id == accountID }) else { return nil }
        return try await refresher.validToken(for: account)
    }

    public func tokenAfterUnauthorized(for accountID: UUID) async throws -> String? {
        guard let account = try accounts().first(where: { $0.id == accountID }) else { return nil }
        return try await refresher.tokenAfterUnauthorized(for: account)
    }
}
