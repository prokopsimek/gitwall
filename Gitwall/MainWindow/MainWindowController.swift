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

    /// Edit › Find… (⌘F). Asked through `@FocusState` from the menu the field never took the keyboard (keyboard
    /// walkthrough 2026-11-03), so the window gives it to the field's AppKit text field directly.
    @objc func focusSearch(_ sender: Any?) {
        guard let window, let field = window.contentView.flatMap(Self.searchField(in:)) else { return }
        window.makeFirstResponder(field)
    }

    /// The search field, by its prompt; the main window has no other text field with it.
    private static func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           (field.placeholderString ?? field.placeholderAttributedString?.string) == MainWindowView.searchPrompt {
            return field
        }
        return view.subviews.lazy.compactMap(searchField(in:)).first
    }
}
