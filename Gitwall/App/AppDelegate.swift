import AppKit
import GitwallCore
import OSLog
import UserNotifications

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var notificationDelegate: NotificationCenterDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be installed before launch finishes so notification clicks that launch the app are delivered.
        let delegate = NotificationCenterDelegate(environment: environment)
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.onOpenSettings = { [weak self] tab in self?.showSettings(tab) }
        statusItem = StatusItemController(environment: environment)
        environment.start()
        applyDebugArguments()
        if environment.needsOnboarding {
            showSettings(.accounts)
        }
    }

    /// Entry point for `gitwall://` URLs coming from widgets and notifications.
    /// Kept in the AppDelegate on purpose: `onOpenURL` on a SwiftUI view is not reliable for a menu bar app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = DeepLink(url: url) else {
                log.error("Ignoring unknown URL \(url.absoluteString, privacy: .public)")
                continue
            }
            environment.handle(link)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if environment.needsOnboarding {
            showSettings(.accounts)
        } else {
            environment.showPopover()
        }
        return false
    }

    func showSettings(_ tab: SettingsTab) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(environment: environment)
        }
        settingsWindow?.show(tab: tab)
    }

    /// Development helper: `Gitwall --debug-github-token <pat> [--debug-repos owner/a,owner/b]`
    /// creates a GitHub account without going through the UI. Debug builds only.
    private func applyDebugArguments() {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--debug-reset") {
            environment.resetAllData()
            log.info("Debug reset performed")
        }
        guard let tokenIndex = args.firstIndex(of: "--debug-github-token"), args.indices.contains(tokenIndex + 1) else { return }
        let token = args[tokenIndex + 1]
        var repos: [String] = []
        if let reposIndex = args.firstIndex(of: "--debug-repos"), args.indices.contains(reposIndex + 1) {
            repos = args[reposIndex + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        guard !environment.config.accounts.contains(where: { $0.kind == .github }) else { return }
        Task {
            do {
                var account = try await environment.addAccount(kind: .github, baseURL: Account.defaultBaseURL(for: .github), token: token)
                account.sources = repos.map { .repository(fullName: $0) }
                environment.updateAccount(account)
                log.info("Debug account created with \(repos.count) repositories")
            } catch {
                log.error("Debug account failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }
}

/// Routes notification clicks to the item they describe.
@MainActor
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let itemID = response.notification.request.content.userInfo[NotificationDispatcher.itemIDKey] as? String
        await MainActor.run {
            if let itemID { environment.open(itemID: itemID) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
