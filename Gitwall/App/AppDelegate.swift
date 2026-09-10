import AppKit
import GitwallCore
import OSLog
import UserNotifications

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "app")

/// Entry point. The app is AppKit-driven (status item, main window, settings window are all
/// `NSWindowController`s) so every window can be opened from the menu bar, the Dock and deep links alike.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.run()
    }

    let environment = AppEnvironment(demo: AppDelegate.isDemoLaunch)
    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var mainMenu: MainMenuController?
    private var notificationDelegate: NotificationCenterDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decide Dock visibility before the Dock registers the process, otherwise the icon flickers or stays generic.
        environment.applyActivationPolicy()
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        mainMenu = MainMenuController(environment: environment)
        // Must be installed before launch finishes so notification clicks that launch the app are delivered.
        let delegate = NotificationCenterDelegate(environment: environment)
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.onOpenSettings = { [weak self] tab in self?.showSettings(tab) }
        environment.onOpenMainWindow = { [weak self] presetID in self?.showMainWindow(presetID: presetID) }
        environment.onShowWidgetHelp = { [weak self] in self?.showWidgetHelp() }
        statusItem = StatusItemController(environment: environment)
        environment.start()
        applyDebugArguments()
        if environment.isDemo {
            presentDemoWindows()
        } else if environment.needsOnboarding {
            showMainWindow(presetID: nil)
        }
    }

    /// `--debug-demo`: sample data instead of the user's; Debug builds only. Used for App Store screenshots.
    private static var isDemoLaunch: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--debug-demo")
        #else
        return false
        #endif
    }

    /// Opens every window the screenshot script captures, at a fixed size so shots are reproducible.
    /// `--debug-demo-preset <index>` picks the preset shown in the main window and popover.
    private func presentDemoWindows() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--debug-demo-preset"), args.indices.contains(index + 1),
           let position = Int(args[index + 1]), environment.config.presets.indices.contains(position) {
            environment.selectedPresetID = environment.config.presets[position].id
        }
        #if DEBUG
        if args.contains("--debug-demo-widgets"), let snapshot = environment.snapshot {
            DemoRenderer.presentWidgetWindows(config: environment.config, snapshot: snapshot)
        }
        #endif
        showMainWindow(presetID: environment.selectedPresetID)
        if let window = mainWindow?.window {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
        }
        showSettings(.presets)
        if let window = settingsWindow?.window {
            window.setContentSize(NSSize(width: 920, height: 720))
            window.center()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.statusItem?.showPopover()
            // The popover stays open in demo mode; hand focus back so the main window is captured as active.
            self?.mainWindow?.window?.makeKeyAndOrderFront(nil)
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

    /// Dock icon click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(presetID: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Windows

    func showMainWindow(presetID: UUID?) {
        if mainWindow == nil {
            mainWindow = MainWindowController(environment: environment)
        }
        mainWindow?.show(presetID: presetID)
    }

    func showSettings(_ tab: SettingsTab) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(environment: environment)
        }
        settingsWindow?.show(tab: tab)
    }

    func showWidgetHelp() {
        showMainWindow(presetID: nil)
        mainWindow?.showWidgetHelp()
    }

    /// Development helper: `Gitwall --debug-reset --debug-github-token <pat> [--debug-repos owner/a,owner/b]`
    /// creates a GitHub account without going through the UI. Debug builds only.
    private func applyDebugArguments() {
        #if DEBUG
        guard !environment.isDemo else { return }
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
