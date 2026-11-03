import AppKit
import GitwallCore

/// What the Walls window answers in the menu bar. The items have no target, so they reach the window controller
/// through the responder chain and stay disabled while another window is in front. The window takes its plain keys
/// (Tab, arrows, Return, Space, 1–4, Delete, Escape) itself; the menu shows them so they can be found. Item actions
/// (Show Detail, Close Detail, Open in Browser) are the Item menu's (`ItemWindowController`), not the Wall menu's.
@MainActor
@objc protocol WallsMenuActions {
    func wallsNextWall(_ sender: Any?)
    func wallsPreviousWall(_ sender: Any?)
    func wallsNextTile(_ sender: Any?)
    func wallsPreviousTile(_ sender: Any?)
    func wallsNextItem(_ sender: Any?)
    func wallsPreviousItem(_ sender: Any?)
    func wallsToggleEditing(_ sender: Any?)
    /// Escape while editing. No menu item shows it; Edit Wall turns editing off as well.
    func wallsFinishEditing(_ sender: Any?)
    /// The menu item's tag is ``TileSize/number``.
    func wallsSetTileSize(_ sender: NSMenuItem)
    /// The menu item's represented object is the preset id.
    func wallsAddTile(_ sender: NSMenuItem)
    func wallsRemoveTile(_ sender: Any?)
    func wallsNewWall(_ sender: Any?)
    func wallsNewWallFromPresets(_ sender: Any?)
    func wallsRenameWall(_ sender: Any?)
    func wallsDuplicateWall(_ sender: Any?)
    func wallsCopyWallAsJSON(_ sender: Any?)
    func wallsDeleteWall(_ sender: Any?)
    func wallsZoomIn(_ sender: Any?)
    func wallsZoomOut(_ sender: Any?)
    func wallsActualSize(_ sender: Any?)
    func wallsToggleRotation(_ sender: Any?)
    /// The menu item's tag is the interval in seconds.
    func wallsSetRotationInterval(_ sender: NSMenuItem)
}

extension TileSize {
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var shortTitle: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .extraLarge: "XL"
        }
    }
}

/// Builds the Wall menu and the Walls items of the View menu, and keeps Add Tile in step with the presets.
@MainActor
final class WallsMenu: NSObject, NSMenuDelegate {
    private let environment: AppEnvironment
    private let addTileMenu = NSMenu(title: "Add Tile")

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        addTileMenu.delegate = self
    }

    /// The Wall menu: moving between walls, tiles and items, and editing walls.
    func wallMenu() -> NSMenu {
        let menu = NSMenu(title: "Wall")
        add(menu, "Next Wall", #selector(WallsMenuActions.wallsNextWall(_:)), "]", [.command, .shift])
        add(menu, "Previous Wall", #selector(WallsMenuActions.wallsPreviousWall(_:)), "[", [.command, .shift])
        // ⌃⇥ and ⌃⇧⇥ as in browser tabs; hidden, because a menu item shows one shortcut.
        hidden(menu, "Next Wall", #selector(WallsMenuActions.wallsNextWall(_:)), "\t", [.control])
        hidden(menu, "Previous Wall", #selector(WallsMenuActions.wallsPreviousWall(_:)), Self.backTab, [.control, .shift])
        menu.addItem(.separator())
        add(menu, "Next Tile", #selector(WallsMenuActions.wallsNextTile(_:)), "\t", [])
        add(menu, "Previous Tile", #selector(WallsMenuActions.wallsPreviousTile(_:)), Self.backTab, [.shift])
        add(menu, "Next Item", #selector(WallsMenuActions.wallsNextItem(_:)), Self.key(NSDownArrowFunctionKey), [])
        add(menu, "Previous Item", #selector(WallsMenuActions.wallsPreviousItem(_:)), Self.key(NSUpArrowFunctionKey), [])
        menu.addItem(.separator())
        add(menu, "Edit Wall", #selector(WallsMenuActions.wallsToggleEditing(_:)), "e")
        let sizes = NSMenu(title: "Tile Size")
        for size in TileSize.allCases {
            let item = add(sizes, size.title, #selector(WallsMenuActions.wallsSetTileSize(_:)), String(size.number), [])
            item.tag = size.number
        }
        menu.addItem(submenu(sizes))
        menu.addItem(submenu(addTileMenu))
        add(menu, "Remove Tile", #selector(WallsMenuActions.wallsRemoveTile(_:)), "\u{8}", [])
        menu.addItem(.separator())
        add(menu, "New Wall", #selector(WallsMenuActions.wallsNewWall(_:)))
        add(menu, "New Wall from Presets", #selector(WallsMenuActions.wallsNewWallFromPresets(_:)))
        add(menu, "Rename Wall…", #selector(WallsMenuActions.wallsRenameWall(_:)))
        add(menu, "Duplicate Wall", #selector(WallsMenuActions.wallsDuplicateWall(_:)))
        add(menu, "Copy Wall as JSON", #selector(WallsMenuActions.wallsCopyWallAsJSON(_:)))
        add(menu, "Delete Wall", #selector(WallsMenuActions.wallsDeleteWall(_:)))
        return menu
    }

    /// Zoom, rotation and full screen, for the end of the View menu.
    func viewItems() -> [NSMenuItem] {
        let menu = NSMenu()
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(WallsMenuActions.wallsZoomIn(_:)), "+")
        hidden(menu, "Zoom In", #selector(WallsMenuActions.wallsZoomIn(_:)), "=", [.command])
        add(menu, "Zoom Out", #selector(WallsMenuActions.wallsZoomOut(_:)), "-")
        add(menu, "Actual Size", #selector(WallsMenuActions.wallsActualSize(_:)), "0")
        menu.addItem(.separator())
        add(menu, "Rotate Walls", #selector(WallsMenuActions.wallsToggleRotation(_:)))
        let intervals = NSMenu(title: "Rotation Interval")
        for seconds in WallRotation.intervals {
            let title = seconds < 60 ? "\(Int(seconds)) Seconds" : Int(seconds) == 60 ? "1 Minute" : "\(Int(seconds / 60)) Minutes"
            add(intervals, title, #selector(WallsMenuActions.wallsSetRotationInterval(_:))).tag = Int(seconds)
        }
        menu.addItem(submenu(intervals))
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    // MARK: Commands

    /// The action of each `WallsCommand`. The keys the window answers itself (`WallsKeys`) are sent as the same
    /// actions, so the menu and the keys are enabled by one rule (`WallsCommand.isEnabled`).
    static func selector(for command: WallsCommand) -> Selector {
        switch command {
        case .nextWall: #selector(WallsMenuActions.wallsNextWall(_:))
        case .previousWall: #selector(WallsMenuActions.wallsPreviousWall(_:))
        case .nextTile: #selector(WallsMenuActions.wallsNextTile(_:))
        case .previousTile: #selector(WallsMenuActions.wallsPreviousTile(_:))
        case .nextItem: #selector(WallsMenuActions.wallsNextItem(_:))
        case .previousItem: #selector(WallsMenuActions.wallsPreviousItem(_:))
        case .showDetail: #selector(ItemWindowController.showItemDetail(_:))
        case .closeDetail: #selector(ItemWindowController.closeItemDetail(_:))
        case .openItemInBrowser: #selector(ItemWindowController.openItemInBrowser(_:))
        case .toggleEditing: #selector(WallsMenuActions.wallsToggleEditing(_:))
        case .finishEditing: #selector(WallsMenuActions.wallsFinishEditing(_:))
        case .setTileSize: #selector(WallsMenuActions.wallsSetTileSize(_:))
        case .addTile: #selector(WallsMenuActions.wallsAddTile(_:))
        case .removeTile: #selector(WallsMenuActions.wallsRemoveTile(_:))
        case .newWall: #selector(WallsMenuActions.wallsNewWall(_:))
        case .newWallFromPresets: #selector(WallsMenuActions.wallsNewWallFromPresets(_:))
        case .renameWall: #selector(WallsMenuActions.wallsRenameWall(_:))
        case .duplicateWall: #selector(WallsMenuActions.wallsDuplicateWall(_:))
        case .copyWallAsJSON: #selector(WallsMenuActions.wallsCopyWallAsJSON(_:))
        case .deleteWall: #selector(WallsMenuActions.wallsDeleteWall(_:))
        case .zoomIn: #selector(WallsMenuActions.wallsZoomIn(_:))
        case .zoomOut: #selector(WallsMenuActions.wallsZoomOut(_:))
        case .actualSize: #selector(WallsMenuActions.wallsActualSize(_:))
        case .toggleRotation: #selector(WallsMenuActions.wallsToggleRotation(_:))
        case .setRotationInterval: #selector(WallsMenuActions.wallsSetRotationInterval(_:))
        }
    }

    static func command(for action: Selector) -> WallsCommand? {
        WallsCommand.allCases.first { selector(for: $0) == action }
    }

    // MARK: NSMenuDelegate

    /// Add Tile lists the presets as they are when the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for preset in environment.config.presets {
            let item = add(menu, preset.name, #selector(WallsMenuActions.wallsAddTile(_:)))
            item.image = NSImage(systemSymbolName: preset.icon, accessibilityDescription: nil)
            item.representedObject = preset.id
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Presets", action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    // MARK: Building

    private static let backTab = String(Character(UnicodeScalar(UInt8(NSBackTabCharacter))))

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }

    @discardableResult
    private func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func hidden(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
        let item = add(menu, title, action, key, modifiers)
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
