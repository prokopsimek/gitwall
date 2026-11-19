import Foundation
import OSLog

/// The sync's part of the unified log.
let syncLog = Logger(subsystem: "cz.prokopsimek.gitwall", category: "sync")

/// What one sync with a selection did, in numbers only. It never holds a query, a login, an organization, a repository or
/// a preset name, so its log line is public.
struct SyncReport: Hashable, Sendable {
    /// Presets each source selected; a preset two sources show counts for both.
    var widgets: Int
    var menuBar: Int
    var notifications: Int
    var windows: Int
    var wall: Int
    /// Preset searches sent, a repeat after a token refresh included.
    var searches: Int
    /// HTTP requests the successful searches took.
    var requests: Int
    /// Items in the snapshot the sync wrote.
    var items: Int
    var duration: Duration

    init(selection: SyncSelection, searches: Int, requests: Int, items: Int, duration: Duration) {
        widgets = selection.widgets.count
        menuBar = selection.menuBar.count
        notifications = selection.notifications.count
        windows = selection.windows.count
        wall = selection.wall.count
        self.searches = searches
        self.requests = requests
        self.items = items
        self.duration = duration
    }

    func write(to log: Logger = syncLog) {
        let milliseconds = Int((duration / .milliseconds(1)).rounded())
        log.info("""
            Synced presets of widgets \(widgets, privacy: .public), menu bar \(menuBar, privacy: .public), \
            notifications \(notifications, privacy: .public), windows \(windows, privacy: .public), \
            wall \(wall, privacy: .public): \(searches, privacy: .public) searches, \
            \(requests, privacy: .public) requests, \(items, privacy: .public) items, \
            \(milliseconds, privacy: .public) ms
            """)
    }
}
