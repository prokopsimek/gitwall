import AppKit
import GitwallCore
import SwiftUI

/// Window › Walls (⌘2): presets side by side as tiles, one tab per wall, made to sit full screen on a second monitor.
/// Answers the Wall menu and the Walls items of the View menu (`WallsMenuActions`) through the responder chain, and
/// as an ``ItemWindowController`` the Item menu for the Detail next to the wall. Hands the window's undo manager to
/// the model and switches walls by itself when rotation is on.
@MainActor
final class WallsWindowController: ItemWindowController {
    let model: WallsModel
    private var rotationTask: Task<Void, Never>?
    private var inputMonitor: Any?
    private var lastAdvance = Date()
    private var lastInput: Date?

    init(environment: AppEnvironment) {
        let model = WallsModel(environment: environment)
        self.model = model
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
        super.init(window: window, environment: environment, detail: model.detail)
        model.undoManager = window.undoManager
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

    /// Tab, the arrows, Return, Space, 1–4, Delete and Escape are not menu shortcuts AppKit delivers (the menu only
    /// takes the arrows), and SwiftUI would use Tab to move focus. So the window takes its keys (`WallsKeys`) before
    /// anything else does, and only when the command is enabled (`WallsCommand.isEnabled`); a disabled one leaves the
    /// key to the window, as Escape to a tab being renamed.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = KeyModifiers(event.modifierFlags)
        guard let key = WallsKeys.action(
            keyCode: event.keyCode, modifiers: modifiers, character: event.charactersIgnoringModifiers ?? "", in: currentState
        ) else { return false }
        let action = WallsMenu.selector(for: key.command)
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = key.tag
        NSApp.sendAction(action, to: self, from: item)
        return true
    }

    private var currentState: WallsState {
        model.state(isKeyWindow: window != nil && NSApp.keyWindow === window, isTyping: isEditingText)
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

    // MARK: Item menu

    /// ⌥⌘I with nothing selected starts at the first item, so the wall and Detail show the same one.
    override func toggleItemDetail(_ sender: Any?) {
        if !detail.isPresented, model.selectedItem == nil { model.selectItem(offset: 1) }
        super.toggleItemDetail(sender)
    }

    /// The Wall and View menus and the Item menu's Show Detail, Close Detail and Open in Browser follow
    /// `WallsCommand.isEnabled`: keys without a modifier act only while this window is the key window and no name is
    /// being typed, so they never fire behind the popover or a sheet. Nothing works while the window shows why it is
    /// empty. The rest of the Item menu is ``ItemWindowController``'s.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let itemMenuAllows = super.validateMenuItem(item)
        guard let action = item.action, let command = WallsMenu.command(for: action) else { return itemMenuAllows }
        switch command {
        case .toggleEditing: item.state = model.isEditing ? .on : .off
        case .setTileSize: item.state = model.selectedTile?.size.number == item.tag ? .on : .off
        case .toggleRotation: item.state = model.rotates ? .on : .off
        case .setRotationInterval: item.state = Int(model.rotation.interval) == item.tag ? .on : .off
        default: break
        }
        return WallsCommand.isEnabled(command, in: currentState)
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

extension WallsWindowController: WallsMenuActions {
    func wallsNextWall(_ sender: Any?) { model.showWall(offset: 1) }
    func wallsPreviousWall(_ sender: Any?) { model.showWall(offset: -1) }
    func wallsNextTile(_ sender: Any?) { model.selectTile(offset: 1) }
    func wallsPreviousTile(_ sender: Any?) { model.selectTile(offset: -1) }
    func wallsNextItem(_ sender: Any?) { model.selectItem(offset: 1) }
    func wallsPreviousItem(_ sender: Any?) { model.selectItem(offset: -1) }
    func wallsToggleEditing(_ sender: Any?) { model.isEditing.toggle() }
    func wallsFinishEditing(_ sender: Any?) { model.isEditing = false }

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

    func wallsRenameWall(_ sender: Any?) { model.beginRename() }

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
}

private extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
