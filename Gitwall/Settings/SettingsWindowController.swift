import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsState {
    var tab: SettingsTab = .accounts
    /// Account preselected in the Repositories tab (set right after adding an account).
    var focusedAccountID: UUID?
}

/// Owns the settings window. Menu bar apps cannot rely on the SwiftUI `Settings` scene being
/// reachable from an NSMenu, so the window is created and shown explicitly here.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let state = SettingsState()

    init(environment: AppEnvironment) {
        let hosting = NSHostingController(rootView: SettingsView(environment: environment, state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Gitwall Settings"
        // Resizable because the preset editor puts a preset list and a form side by side; at a fixed 640 pt the
        // form's text fields were squeezed to nothing and looked read-only.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        window.setFrameAutosaveName("GitwallSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(tab: SettingsTab, accountID: UUID? = nil) {
        state.tab = tab
        if let accountID { state.focusedAccountID = accountID }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
