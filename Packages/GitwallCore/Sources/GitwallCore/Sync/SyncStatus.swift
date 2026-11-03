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
        updatedAt = snapshot?.fetchedAt
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

    private static func age(since date: Date, now: Date) -> String {
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
