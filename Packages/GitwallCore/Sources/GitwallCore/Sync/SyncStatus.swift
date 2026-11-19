import Foundation

/// How fresh the items on screen are, for a wall nobody looks at closely: "Updated 2 min ago", or why the last
/// sync failed and how old the data is.
public struct SyncStatus: Equatable, Sendable {
    /// When the data on screen was fetched, if ever.
    public var updatedAt: Date?
    /// Why the last sync failed, or nil when it worked.
    public var failure: String?

    public var isFailure: Bool { failure != nil }

    /// A sync that threw explains itself first; otherwise the first configured account whose last fetch failed,
    /// dated by its own last success. Accounts that are no longer configured do not count.
    public init(snapshot: Snapshot?, accounts: [Account], lastError: String?) {
        updatedAt = Self.dataDate(of: snapshot, accounts: accounts)
        if let lastError {
            failure = lastError
            return
        }
        for account in accounts {
            guard let status = snapshot?.accountStatus[account.id], status.state != .ok else { continue }
            failure = "\(account.displayName): \(status.message ?? Self.describe(status.state))"
            updatedAt = status.lastSuccessAt
            return
        }
        failure = nil
    }

    /// English, user-facing.
    public func text(now: Date) -> String {
        let age = updatedAt.map { Self.age(since: $0, now: now) }
        guard let failure else {
            return age.map { "Updated \($0)" } ?? "Not updated yet"
        }
        return ["Sync failed: \(failure)", age.map { "updated \($0)" }].compactMap(\.self).joined(separator: " · ")
    }

    /// When the oldest data on screen was fetched. An account in a series of failed syncs (``FetchStatus/consecutiveFailures``
    /// above 0, quiet or not) still shows what it had at its last success, so that date counts rather than the snapshot's.
    /// One that never synced leaves the data undated, "Not updated yet", instead of a misleading recent time.
    private static func dataDate(of snapshot: Snapshot?, accounts: [Account]) -> Date? {
        guard let snapshot else { return nil }
        let failing = accounts.compactMap { snapshot.accountStatus[$0.id] }.filter { $0.consecutiveFailures > 0 }
        guard !failing.isEmpty else { return snapshot.fetchedAt }
        let dates = failing.map(\.lastSuccessAt)
        return dates.contains(nil) ? nil : dates.compactMap(\.self).min()
    }

    /// How long ago `date` was, as the status says it: "just now", "5 min ago", "3 h ago", "2 d ago". English,
    /// user-facing; also what a preset's count says about when the preset was fetched.
    public static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    private static func describe(_ state: FetchState) -> String {
        switch state {
        case .ok: "ok"
        case .error: "the last sync failed"
        case .rateLimited: "rate limited"
        case .needsReauth: "sign in again"
        }
    }
}
