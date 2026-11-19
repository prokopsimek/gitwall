import Foundation
import OSLog

/// The sync's part of the unified log.
let syncLog = Logger(subsystem: "cz.prokopsimek.gitwall", category: "sync")

/// What one sync with a selection or one on-demand fetch did, in numbers only. It never holds a query, a login, an
/// organization, a repository or a preset name, so its log line is public.
struct SyncReport: Hashable, Sendable {
    /// What the presets were fetched for.
    enum Origin: Hashable, Sendable {
        /// A sync with a ``SyncSelection``: the presets each source selected; a preset two sources show counts for both.
        case selection(widgets: Int, menuBar: Int, notifications: Int, windows: Int, wall: Int)
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

    init(selection: SyncSelection, searches: Int, requests: Int, items: Int, duration: Duration) {
        origin = .selection(widgets: selection.widgets.count, menuBar: selection.menuBar.count,
                            notifications: selection.notifications.count, windows: selection.windows.count,
                            wall: selection.wall.count)
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
        case .selection(let widgets, let menuBar, let notifications, let windows, let wall):
            return "Synced presets of widgets \(widgets), menu bar \(menuBar), notifications \(notifications), "
                + "windows \(windows), wall \(wall): \(counts)"
        case .onDemand(let presets, let failedAccounts):
            return "Fetched \(presets) presets on demand, failed accounts \(failedAccounts): \(counts)"
        }
    }

    func write(to log: Logger = syncLog) {
        log.info("\(message, privacy: .public)")
    }
}
