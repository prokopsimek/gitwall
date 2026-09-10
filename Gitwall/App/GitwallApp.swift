import SwiftUI

@main
struct GitwallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The settings window is managed by SettingsWindowController (AppKit) so it can be opened
        // reliably from the status item menu. This scene only exists to satisfy the App protocol
        // and to provide the standard ⌘, shortcut when a window is key.
        Settings {
            SettingsView(environment: appDelegate.environment, state: SettingsState())
        }
    }
}
