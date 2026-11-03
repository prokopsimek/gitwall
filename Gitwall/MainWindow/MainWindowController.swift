import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MainWindowState {
    var showingWidgetHelp = false
}

/// The main window: presets in a sidebar, items in the middle, Detail of the selected item on the right. Opened from
/// the Dock, the Window menu, the status item menu and `gitwall://view` deep links. Closing it keeps the app running.
@MainActor
final class MainWindowController: ItemWindowController {
    let state = MainWindowState()

    init(environment: AppEnvironment) {
        let detail = DetailModel(environment: environment)
        let hosting = NSHostingController(rootView: MainWindowView(environment: environment, state: state, detail: detail))
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
        super.init(window: window, environment: environment, detail: detail)
        #if DEBUG
        // `--debug-detail owner/repo#123` opens Detail of that item, for screenshots without clicking.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--debug-detail"), args.indices.contains(index + 1),
           let item = environment.snapshot?.items.first(where: { "\($0.repoFullName)#\($0.number)" == args[index + 1] }) {
            detail.show(item.id)
        }
        #endif
    }

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
