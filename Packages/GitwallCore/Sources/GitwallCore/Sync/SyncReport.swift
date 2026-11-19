import Foundation
import OSLog

/// The sync's part of the unified log.
let syncLog = Logger(subsystem: "cz.prokopsimek.gitwall", category: "sync")

/// What one sync with a selection or one on-demand fetch did, in numbers only. It never holds a query, a login, an
/// organization, a repository or a preset name, so its log line is public.
struct SyncReport: Hashable, Sendable {
    /// What the presets were fetched for.
    enum Origin: Hashable, Sendable {
        /// A sync with a ``SyncSelection``: the presets each source selected, where a preset two sources show counts
        /// for both, and the accounts an account error stopped, a quiet one included.
        case selection(widgets: Int, menuBar: Int, notifications: Int, windows: Int, wall: Int, failedAccounts: Int)
        /// ``SyncEngine/syncPresets(_:)``: the presets it fetched, and the accounts an account error stopped.
        case onDemand(presets: Int, failedAccounts: Int)
    }

    var origin: Origin
    /// Preset searches sent, a repeat after a token refresh included.
    var searches: Int
    /// HTTP requests the successful searches took, and one per item state lookup.
    var requests: Int
    /// Items in the snapshot the sync wrote.
    var items: Int
    var duration: Duration

    init(selection: SyncSelection, failedAccounts: Int = 0, searches: Int, requests: Int, items: Int,
         duration: Duration) {
        origin = .selection(widgets: selection.widgets.count, menuBar: selection.menuBar.count,
                            notifications: selection.notifications.count, windows: selection.windows.count,
                            wall: selection.wall.count, failedAccounts: failedAccounts)
        self.searches = searches
        self.requests = requests
        self.items = items
        self.duration = duration
    }

    init(onDemand presets: Int, failedAccounts: Int, searches: Int, requests: Int, items: Int, duration: Duration) {
        origin = .onDemand(presets: presets, failedAccounts: failedAccounts)
        self.searches = searches
        self.requests = requests
        self.items = items
        self.duration = duration
    }

    /// The log line, made of counts alone.
    var message: String {
        let milliseconds = Int((duration / .milliseconds(1)).rounded())
        let counts = "\(searches) searches, \(requests) requests, \(items) items, \(milliseconds) ms"
        switch origin {
        case .selection(let widgets, let menuBar, let notifications, let windows, let wall, let failedAccounts):
            // A sync in which every account worked leaves the count out.
            let failed = failedAccounts > 0 ? ", failed accounts \(failedAccounts)" : ""
            return "Synced presets of widgets \(widgets), menu bar \(menuBar), notifications \(notifications), "
                + "windows \(windows), wall \(wall)\(failed): \(counts)"
        case .onDemand(let presets, let failedAccounts):
            return "Fetched \(presets) presets on demand, failed accounts \(failedAccounts): \(counts)"
        }
    }

    func write(to log: Logger = syncLog) {
        log.info("\(message, privacy: .public)")
    }
}

/// An account a regular sync could not fetch for a passing reason, a gateway error, a lost connection or an answer
/// that could not be read, and which still shows what it showed before (see ``SyncEngine``). Without a line of its own
/// such a sync would read as a success in the log. It holds the provider, the kind of error and the failure's place in
/// the series, never the error's message, which could carry a URL or a login.
struct QuietFailure: Hashable, Sendable {
    let provider: ProviderKind
    /// The error by its case, such as `network` or `server 502`.
    let error: String
    /// Which failed sync in a row this is, from 1 to ``SyncEngine/quietFailures``.
    let failure: Int

    init(provider: ProviderKind, error: any Error, failure: Int) {
        self.provider = provider
        self.error = Self.kind(of: error)
        self.failure = failure
    }

    /// The log line, without a message, an id or a name.
    var message: String {
        "A \(provider.rawValue) account failed quietly (\(error)), \(failure) of \(SyncEngine.quietFailures)"
    }

    func write(to log: Logger = syncLog) {
        log.info("\(message, privacy: .public)")
    }

    /// `error` by its case, with the status of a server error, or by its type when it is no ``ProviderError``.
    private static func kind(of error: any Error) -> String {
        switch error as? ProviderError {
        case .server(let status, _): "server \(status)"
        case .network: "network"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rateLimited"
        case .invalidResponse: "invalidResponse"
        case .notFound: "notFound"
        case .unsupported: "unsupported"
        case nil: String(describing: type(of: error))
        }
    }
}
