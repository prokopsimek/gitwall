import Foundation

/// How a failed ``GitProvider/fetchPresetItems(account:token:search:)`` counts in a sync: against the one preset, or
/// against the whole account.
enum PresetSearchFailure: Hashable, Sendable {
    /// The provider refused this one search while the account worked: GraphQL errors in a 200 answer (status 200) or a
    /// rejected search (400, 422). `code` is the status alone, so it never carries the query, a login or a name.
    case query(code: String)
    /// The account failed: a rejected token, a rate limit, a server error, no connection or anything unexpected. Its
    /// remaining searches wait for the next sync.
    case account

    init(_ error: any Error) {
        switch error as? ProviderError {
        case .server(let status, _) where [200, 400, 422].contains(status):
            self = .query(code: String(status))
        default:
            self = .account
        }
    }
}
