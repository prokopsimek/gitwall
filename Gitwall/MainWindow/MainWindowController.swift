import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MainWindowState {
    var showingWidgetHelp = false
}

/// The main window: presets in a sidebar, items on the right. Opened from the Dock, the Window menu,
/// the status item menu and `gitwall://view` deep links. Closing it keeps the app running.
@MainActor
final class MainWindowController: NSWindowController {
    private let environment: AppEnvironment
    let state = MainWindowState()

    init(environment: AppEnvironment) {
        self.environment = environment
        let hosting = NSHostingController(rootView: MainWindowView(environment: environment, state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Gitwall"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        window.setFrameAutosaveName("GitwallMain")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(presetID: UUID?) {
        if let presetID, environment.config.preset(id: presetID) != nil {
            environment.selectedPresetID = presetID
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showWidgetHelp() {
        state.showingWidgetHelp = true
    }
}
