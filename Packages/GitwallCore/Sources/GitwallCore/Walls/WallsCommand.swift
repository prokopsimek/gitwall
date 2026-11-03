import Foundation

/// What the Walls window can do from its menus and keys. The app maps each to a menu action; when a command is
/// available is decided here (``isEnabled(_:in:)``), for the menu and the keys alike.
public enum WallsCommand: String, CaseIterable, Sendable {
    case nextWall, previousWall
    case nextTile, previousTile
    case nextItem, previousItem
    case openItem, openItemInBrowser
    case toggleEditing, finishEditing
    case setTileSize, addTile, removeTile
    case newWall, newWallFromPresets, renameWall, duplicateWall, copyWallAsJSON, deleteWall
    case zoomIn, zoomOut, actualSize
    case toggleRotation, setRotationInterval

    /// Answered by a key without ⌘, ⌥ or ⌃ (Tab, arrows, Return, Space, 1–4, Delete, Escape). Such a key belongs
    /// to whatever window is in front, so the command only acts in the key Walls window and never while a name is
    /// being typed.
    public var usesPlainKey: Bool {
        switch self {
        case .nextTile, .previousTile, .nextItem, .previousItem, .openItem, .setTileSize, .removeTile, .finishEditing:
            true
        default:
            false
        }
    }

    public static func isEnabled(_ command: WallsCommand, in state: WallsState) -> Bool {
        guard state.hasContent else { return false }
        if command.usesPlainKey, !state.isKeyWindow || state.isTyping { return false }
        let hasWall = state.wallCount > 0
        switch command {
        case .nextWall, .previousWall:
            return state.wallCount > 1
        case .nextTile, .previousTile:
            return state.tileCount > 0
        case .nextItem, .previousItem:
            return !state.isEditing && state.tileCount > 0
        case .openItem, .openItemInBrowser:
            return !state.isEditing && state.hasSelectedItem
        case .toggleEditing, .addTile, .renameWall, .duplicateWall, .copyWallAsJSON, .deleteWall:
            return hasWall
        case .finishEditing:
            return state.isEditing
        case .setTileSize, .removeTile:
            return state.isEditing && state.hasSelectedTile
        case .newWall, .toggleRotation, .setRotationInterval:
            return true
        case .newWallFromPresets:
            return state.presetCount > 0
        case .zoomIn:
            return state.zoom < (WallLayout.zoomLevels.last ?? 1)
        case .zoomOut:
            return state.zoom > (WallLayout.zoomLevels.first ?? 1)
        case .actualSize:
            return state.zoom != 1
        }
    }
}

/// What ``WallsCommand/isEnabled(_:in:)`` needs to know about the Walls window.
public struct WallsState: Equatable, Sendable {
    /// The Walls window is the key window, not just the main one behind a popover or a sheet.
    public var isKeyWindow: Bool
    /// A text field has the keyboard, as when a wall is being renamed.
    public var isTyping: Bool
    /// False while the window explains why it is empty (no container, no account).
    public var hasContent: Bool
    public var wallCount: Int
    /// Tiles of the wall on screen.
    public var tileCount: Int
    public var hasSelectedTile: Bool
    public var hasSelectedItem: Bool
    public var isEditing: Bool
    public var presetCount: Int
    public var zoom: Double

    public init(
        isKeyWindow: Bool, isTyping: Bool, hasContent: Bool, wallCount: Int, tileCount: Int,
        hasSelectedTile: Bool, hasSelectedItem: Bool, isEditing: Bool, presetCount: Int, zoom: Double
    ) {
        self.isKeyWindow = isKeyWindow
        self.isTyping = isTyping
        self.hasContent = hasContent
        self.wallCount = wallCount
        self.tileCount = tileCount
        self.hasSelectedTile = hasSelectedTile
        self.hasSelectedItem = hasSelectedItem
        self.isEditing = isEditing
        self.presetCount = presetCount
        self.zoom = zoom
    }
}

/// The modifier keys that tell shortcuts apart; others (Caps Lock, Fn, the keypad flag) do not count.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// The keys the Walls window answers itself. AppKit does not deliver plain printable keys as menu shortcuts and
/// SwiftUI would spend Tab on focus, so the window reads them before anything else; the menus show the same keys.
public enum WallsKeys {
    public struct Action: Equatable, Sendable {
        public var command: WallsCommand
        /// ``TileSize/number`` for ``WallsCommand/setTileSize``, otherwise 0.
        public var tag: Int

        public init(_ command: WallsCommand, tag: Int = 0) {
            self.command = command
            self.tag = tag
        }
    }

    /// Virtual key codes of the keys involved; positions, so they hold on every keyboard layout.
    enum KeyCode {
        static let tab: UInt16 = 48, returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49
        static let down: UInt16 = 125, up: UInt16 = 126, escape: UInt16 = 53
        static let delete: UInt16 = 51, forwardDelete: UInt16 = 117
        static let rightBracket: UInt16 = 30, leftBracket: UInt16 = 33
        /// 1 to 4 on the number row and on the keypad.
        static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 83: 1, 84: 2, 85: 3, 86: 4]
    }

    /// - Parameter character: The key's character ignoring modifiers but Shift, for the brackets on layouts where
    ///   they are not where a US keyboard has them.
    public static func action(keyCode: UInt16, modifiers: KeyModifiers, character: String) -> Action? {
        switch (keyCode, modifiers) {
        case (KeyCode.tab, []): return Action(.nextTile)
        case (KeyCode.tab, .shift): return Action(.previousTile)
        case (KeyCode.tab, .control): return Action(.nextWall)
        case (KeyCode.tab, [.control, .shift]): return Action(.previousWall)
        case (KeyCode.down, []): return Action(.nextItem)
        case (KeyCode.up, []): return Action(.previousItem)
        case (KeyCode.returnKey, []), (KeyCode.enter, []), (KeyCode.space, []): return Action(.openItem)
        case (KeyCode.returnKey, .command), (KeyCode.enter, .command): return Action(.openItemInBrowser)
        case (KeyCode.delete, []), (KeyCode.forwardDelete, []): return Action(.removeTile)
        case (KeyCode.escape, []): return Action(.finishEditing)
        case (_, [.command, .shift]) where keyCode == KeyCode.rightBracket || character == "}" || character == "]":
            return Action(.nextWall)
        case (_, [.command, .shift]) where keyCode == KeyCode.leftBracket || character == "{" || character == "[":
            return Action(.previousWall)
        case (_, []), (_, .shift):
            return KeyCode.digits[keyCode].map { Action(.setTileSize, tag: $0) }
        default:
            return nil
        }
    }
}
