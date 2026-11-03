import AppKit
import GitwallCore
import SwiftUI

/// Window › Walls (⌘2): presets side by side as tiles, one tab per wall, made to sit full screen on a second monitor.
/// Answers the Wall menu and the Walls items of the View menu (`WallsMenuActions`) through the responder chain, hands
/// the window's undo manager to the model and switches walls by itself when rotation is on.
@MainActor
final class WallsWindowController: NSWindowController, NSWindowDelegate {
    let model: WallsModel
    private var rotationTask: Task<Void, Never>?
    private var inputMonitor: Any?
    private var lastAdvance = Date()
    private var lastInput: Date?

    init(environment: AppEnvironment) {
        model = WallsModel(environment: environment)
        let hosting = NSHostingController(rootView: WallsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Walls"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // The green button and ⌃⌘F give the wall a monitor of its own.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("GitwallWalls")
        super.init(window: window)
        window.delegate = self
        model.undoManager = window.undoManager
        // Clicking an item, Return and Space go through this one hook. It opens the item in the browser for now.
        model.onActivate = { [weak environment] item in environment?.open(item) }
        // Someone using the window holds the rotation for two minutes (`WallRotation.pauseAfterInput`). The same
        // monitor answers the window's keys, see `handleKey`.
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
                self.lastInput = Date()
                return event.type == .keyDown && self.handleKey(event)
            }
            return handled ? nil : event
        }
        scheduleRotation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Keys

    /// Tab, the arrows, Return, Space, 1–4 and Delete are not menu shortcuts AppKit delivers (the menu only takes
    /// the arrows), and SwiftUI would use Tab to move focus. So the window takes them before anything else does, as
    /// long as no name is being typed, and only when the menu item that shows the key is enabled.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !(window?.firstResponder is NSText) else { return false }
        if event.keyCode == KeyCode.escape, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]), model.isEditing {
            model.isEditing = false
            return true
        }
        guard let (action, tag) = Self.shortcut(for: event) else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        guard validateMenuItem(item) else { return false }
        NSApp.sendAction(action, to: self, from: item)
        return true
    }

    private enum KeyCode {
        static let tab: UInt16 = 48, returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49
        static let down: UInt16 = 125, up: UInt16 = 126, delete: UInt16 = 51, forwardDelete: UInt16 = 117, escape: UInt16 = 53
        static let rightBracket: UInt16 = 30, leftBracket: UInt16 = 33
        /// 1 to 4 on the number row and on the keypad, by position, so the keys work on layouts that need Shift for
        /// digits.
        static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 83: 1, 84: 2, 85: 3, 86: 4]
    }

    /// The action, and the tag it reads, for a key of the Walls window.
    private static func shortcut(for event: NSEvent) -> (Selector, Int)? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, flags) {
        case (KeyCode.tab, []): return (#selector(wallsNextTile(_:)), 0)
        case (KeyCode.tab, [.shift]): return (#selector(wallsPreviousTile(_:)), 0)
        case (KeyCode.tab, [.control]): return (#selector(wallsNextWall(_:)), 0)
        case (KeyCode.tab, [.control, .shift]): return (#selector(wallsPreviousWall(_:)), 0)
        case (KeyCode.down, []): return (#selector(wallsNextItem(_:)), 0)
        case (KeyCode.up, []): return (#selector(wallsPreviousItem(_:)), 0)
        case (KeyCode.returnKey, []), (KeyCode.enter, []), (KeyCode.space, []): return (#selector(wallsOpenItem(_:)), 0)
        case (KeyCode.returnKey, [.command]), (KeyCode.enter, [.command]): return (#selector(wallsOpenItemInBrowser(_:)), 0)
        case (KeyCode.delete, []), (KeyCode.forwardDelete, []): return (#selector(wallsRemoveTile(_:)), 0)
        case (_, [.command, .shift]) where event.keyCode == KeyCode.rightBracket || character == "}" || character == "]":
            return (#selector(wallsNextWall(_:)), 0)
        case (_, [.command, .shift]) where event.keyCode == KeyCode.leftBracket || character == "{" || character == "[":
            return (#selector(wallsPreviousWall(_:)), 0)
        case (_, []), (_, [.shift]):
            return KeyCode.digits[event.keyCode].map { (#selector(wallsSetTileSize(_:)), $0) }
        default:
            return nil
        }
    }

    // MARK: Rotation

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        guard model.rotates else { return }
        lastAdvance = Date()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let wait = model.rotation.nextAdvance(lastAdvance: lastAdvance, lastInput: lastInput).timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                } else {
                    rotate()
                }
            }
        }
    }

    /// An open window moves on, also behind other windows or in Stage Manager's strip, so the wall is where the
    /// rotation says when someone looks; never while it is being edited or renamed.
    private func rotate() {
        lastAdvance = Date()
        guard window?.isVisible == true, !model.isEditing, model.renamingWallID == nil else { return }
        model.showWall(offset: 1)
    }

    #if DEBUG
    /// `--debug-demo-walls <window|edit|empty|fullscreen>`: a fixed window size, and the state to capture.
    func prepareScreenshot(_ mode: String) {
        window?.setContentSize(NSSize(width: 1280, height: 800))
        window?.center()
        model.zoom = 1
        switch mode {
        case "edit":
            model.isEditing = true
            model.selectTile(offset: 1)
        case "fullscreen":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.window?.toggleFullScreen(nil) }
        default:
            model.selectItem(offset: 1)
        }
    }
    #endif
}

// MARK: - Menu actions

extension WallsWindowController: WallsMenuActions, NSMenuItemValidation {
    func wallsNextWall(_ sender: Any?) { model.showWall(offset: 1) }
    func wallsPreviousWall(_ sender: Any?) { model.showWall(offset: -1) }
    func wallsNextTile(_ sender: Any?) { model.selectTile(offset: 1) }
    func wallsPreviousTile(_ sender: Any?) { model.selectTile(offset: -1) }
    func wallsNextItem(_ sender: Any?) { model.selectItem(offset: 1) }
    func wallsPreviousItem(_ sender: Any?) { model.selectItem(offset: -1) }
    func wallsOpenItem(_ sender: Any?) { model.activateSelection() }
    func wallsOpenItemInBrowser(_ sender: Any?) { model.openSelectionInBrowser() }
    func wallsToggleEditing(_ sender: Any?) { model.isEditing.toggle() }

    func wallsSetTileSize(_ sender: NSMenuItem) {
        guard let tile = model.selectedTile, let size = TileSize(number: sender.tag) else { return }
        model.setSize(size, ofTile: tile.id)
    }

    func wallsAddTile(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? UUID else { return }
        model.addTile(presetID: presetID)
    }

    func wallsRemoveTile(_ sender: Any?) {
        if let tile = model.selectedTile { model.removeTile(tile.id) }
    }

    func wallsNewWall(_ sender: Any?) { model.newWall() }
    func wallsNewWallFromPresets(_ sender: Any?) { model.newWallFromPresets() }

    func wallsRenameWall(_ sender: Any?) {
        model.renamingWallID = model.currentWall?.id
    }

    func wallsDuplicateWall(_ sender: Any?) {
        if let wall = model.currentWall { model.duplicate(wall.id) }
    }

    func wallsCopyWallAsJSON(_ sender: Any?) {
        if let wall = model.currentWall { ConfigurationPaste.copy(wall, environment: model.environment) }
    }

    func wallsDeleteWall(_ sender: Any?) {
        if let wall = model.currentWall { model.delete(wall.id) }
    }

    func wallsZoomIn(_ sender: Any?) { model.zoom(step: 1) }
    func wallsZoomOut(_ sender: Any?) { model.zoom(step: -1) }
    func wallsActualSize(_ sender: Any?) { model.zoom(step: 0) }

    func wallsToggleRotation(_ sender: Any?) {
        model.rotates.toggle()
        scheduleRotation()
    }

    func wallsSetRotationInterval(_ sender: NSMenuItem) {
        model.rotation = WallRotation(storedInterval: TimeInterval(sender.tag))
        scheduleRotation()
    }

    /// Plain keys (Tab, arrows, Return, Space, 1–4, Delete) are menu shortcuts here, so they give way while a name is
    /// being typed. Nothing works while the window shows why it is empty.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let environment = model.environment
        guard environment.containerAvailable, !environment.needsOnboarding else { return false }
        let typing = window?.firstResponder is NSText
        let hasWall = model.currentWall != nil
        let hasTile = model.selectedTile != nil
        switch item.action {
        case #selector(wallsNextWall(_:)), #selector(wallsPreviousWall(_:)):
            return model.walls.count > 1
        case #selector(wallsNextTile(_:)), #selector(wallsPreviousTile(_:)):
            return !typing && !(model.currentWall?.tiles.isEmpty ?? true)
        case #selector(wallsNextItem(_:)), #selector(wallsPreviousItem(_:)):
            return !typing && !model.isEditing && !(model.currentWall?.tiles.isEmpty ?? true)
        case #selector(wallsOpenItem(_:)), #selector(wallsOpenItemInBrowser(_:)):
            return !typing && !model.isEditing && model.selectedItem != nil
        case #selector(wallsToggleEditing(_:)):
            item.state = model.isEditing ? .on : .off
            return hasWall
        case #selector(wallsSetTileSize(_:)):
            item.state = model.selectedTile?.size.number == item.tag ? .on : .off
            return !typing && model.isEditing && hasTile
        case #selector(wallsRemoveTile(_:)):
            return !typing && model.isEditing && hasTile
        case #selector(wallsAddTile(_:)), #selector(wallsRenameWall(_:)), #selector(wallsDuplicateWall(_:)),
             #selector(wallsCopyWallAsJSON(_:)), #selector(wallsDeleteWall(_:)):
            return hasWall
        case #selector(wallsNewWallFromPresets(_:)):
            return !environment.config.presets.isEmpty
        case #selector(wallsZoomIn(_:)):
            return model.zoom < (WallLayout.zoomLevels.last ?? 1)
        case #selector(wallsZoomOut(_:)):
            return model.zoom > (WallLayout.zoomLevels.first ?? 1)
        case #selector(wallsActualSize(_:)):
            return model.zoom != 1
        case #selector(wallsToggleRotation(_:)):
            item.state = model.rotates ? .on : .off
            return true
        case #selector(wallsSetRotationInterval(_:)):
            item.state = Int(model.rotation.interval) == item.tag ? .on : .off
            return true
        default:
            return true
        }
    }
}
