import Foundation
import Testing
@testable import GitwallCore

@Suite("Walls commands")
struct WallsCommandTests {
    /// The Walls window in front with a wall of tiles, a tile and an item selected and Detail open, nothing typed.
    private var ready: WallsState {
        WallsState(isKeyWindow: true, isTyping: false, hasContent: true, wallCount: 2, tileCount: 3,
                   hasSelectedTile: true, hasSelectedItem: true, isEditing: false, presetCount: 4, zoom: 1,
                   isDetailPresented: true)
    }

    private func enabled(_ command: WallsCommand, _ change: (inout WallsState) -> Void = { _ in }) -> Bool {
        var state = ready
        change(&state)
        return WallsCommand.isEnabled(command, in: state)
    }

    // MARK: - Enabling

    @Test("plain keys act only in the key Walls window and never while a name is typed")
    func plainKeysNeedTheKeyWindow() {
        let plain = WallsCommand.allCases.filter(\.usesPlainKey)
        #expect(Set(plain) == [
            .nextTile, .previousTile, .nextItem, .previousItem, .showDetail, .closeDetail, .setTileSize, .removeTile, .finishEditing,
        ])
        for command in plain {
            #expect(!enabled(command) { $0.isKeyWindow = false; $0.isEditing = command.needsEditing })
            #expect(!enabled(command) { $0.isTyping = true; $0.isEditing = command.needsEditing })
            #expect(enabled(command) { $0.isEditing = command.needsEditing })
        }
        // Commands with a modifier still work while another window of the app is in front, as menus do.
        #expect(enabled(.nextWall) { $0.isKeyWindow = false })
        #expect(enabled(.toggleEditing) { $0.isTyping = true })
    }

    @Test("nothing works while the window explains why it is empty")
    func noContent() {
        for command in WallsCommand.allCases {
            #expect(!enabled(command) { $0.hasContent = false })
        }
    }

    @Test("each command needs what it acts on")
    func requirements() {
        #expect(!enabled(.nextWall) { $0.wallCount = 1 })
        #expect(!enabled(.nextTile) { $0.tileCount = 0 })
        #expect(!enabled(.nextItem) { $0.isEditing = true })
        #expect(!enabled(.showDetail) { $0.hasSelectedItem = false })
        #expect(!enabled(.showDetail) { $0.isEditing = true })
        #expect(!enabled(.closeDetail) { $0.isDetailPresented = false })
        #expect(!enabled(.closeDetail) { $0.isEditing = true })
        #expect(!enabled(.openItemInBrowser) { $0.isEditing = true })
        #expect(!enabled(.openItemInBrowser) { $0.hasSelectedItem = false })
        #expect(!enabled(.setTileSize))
        #expect(enabled(.setTileSize) { $0.isEditing = true })
        #expect(!enabled(.removeTile) { $0.isEditing = true; $0.hasSelectedTile = false })
        #expect(!enabled(.finishEditing))
        #expect(!enabled(.toggleEditing) { $0.wallCount = 0 })
        #expect(!enabled(.deleteWall) { $0.wallCount = 0 })
        #expect(enabled(.newWall) { $0.wallCount = 0 })
        #expect(!enabled(.newWallFromPresets) { $0.presetCount = 0 })
        #expect(!enabled(.zoomOut) { $0.zoom = WallLayout.zoomLevels.first! })
        #expect(!enabled(.zoomIn) { $0.zoom = WallLayout.zoomLevels.last! })
        #expect(!enabled(.actualSize))
        #expect(enabled(.actualSize) { $0.zoom = 1.5 })
    }

    // MARK: - Keys

    @Test("keys of the Walls window, by key and modifiers")
    func keys() {
        func command(_ code: UInt16, _ modifiers: KeyModifiers = [], _ character: String = "") -> WallsKeys.Action? {
            WallsKeys.action(keyCode: code, modifiers: modifiers, character: character)
        }
        #expect(command(48) == .init(.nextTile))
        #expect(command(48, .shift) == .init(.previousTile))
        #expect(command(48, .control) == .init(.nextWall))
        #expect(command(48, [.control, .shift]) == .init(.previousWall))
        #expect(command(125) == .init(.nextItem))
        #expect(command(126) == .init(.previousItem))
        #expect(command(36) == .init(.showDetail))
        #expect(command(49) == .init(.showDetail))
        #expect(command(76) == .init(.showDetail))
        #expect(command(36, .command) == .init(.openItemInBrowser))
        #expect(command(51) == .init(.removeTile))
        #expect(command(117) == .init(.removeTile))
        #expect(command(53) == .init(.finishEditing))
        #expect(command(30, [.command, .shift], "}") == .init(.nextWall))
        #expect(command(33, [.command, .shift], "{") == .init(.previousWall))
        // On a layout where the bracket sits elsewhere, the character decides.
        #expect(command(27, [.command, .shift], "]") == .init(.nextWall))
        // 1–4 by position, with or without Shift, so layouts that need Shift for digits work too.
        #expect(command(18) == .init(.setTileSize, tag: 1))
        #expect(command(21, .shift) == .init(.setTileSize, tag: 4))
        #expect(command(86) == .init(.setTileSize, tag: 4))
        #expect(command(18, .command) == nil)
        #expect(command(48, .option) == nil)
        #expect(command(0, [], "a") == nil)
    }

    @Test("Escape finishes editing first, then closes Detail; while a name is typed it is the text field's")
    func escape() {
        func escape(_ change: (inout WallsState) -> Void) -> WallsKeys.Action? {
            var state = ready
            change(&state)
            return WallsKeys.action(keyCode: 53, modifiers: [], character: "", in: state)
        }
        #expect(escape { $0.isEditing = true } == .init(.finishEditing))
        #expect(escape { _ in } == .init(.closeDetail))
        #expect(escape { $0.isDetailPresented = false } == nil)
        #expect(escape { $0.isTyping = true } == nil)
        #expect(escape { $0.isKeyWindow = false } == nil)
    }

    @Test("a key whose command is disabled is left to the rest of the window")
    func disabledKeys() {
        var state = ready
        state.hasSelectedItem = false
        #expect(WallsKeys.action(keyCode: 49, modifiers: [], character: " ", in: state) == nil)
        #expect(WallsKeys.action(keyCode: 125, modifiers: [], character: "", in: state) == .init(.nextItem))
        #expect(WallsKeys.action(keyCode: 0, modifiers: [], character: "a", in: state) == nil)
    }

    // MARK: - Selection after a change

    @Test("an added or changed wall is selected; removing the selected one selects its neighbour")
    func selection() {
        let a = Wall(name: "A"), b = Wall(name: "B"), c = Wall(name: "C")
        #expect(WallNavigation.selection(after: WallChange(before: nil, after: c, index: 2), in: [a, b, c], selected: a.id) == .select(c.id))
        #expect(WallNavigation.selection(after: WallChange(before: a, after: a, index: 0), in: [a, b], selected: a.id) == .keep)
        // Deleting the last one selects the one before it; deleting the only one selects none.
        #expect(WallNavigation.selection(after: WallChange(before: c, after: nil, index: 2), in: [a, b], selected: c.id) == .select(b.id))
        #expect(WallNavigation.selection(after: WallChange(before: b, after: nil, index: 1), in: [a, c], selected: b.id) == .select(c.id))
        #expect(WallNavigation.selection(after: WallChange(before: a, after: nil, index: 0), in: [], selected: a.id) == .select(nil))
        // Deleting another wall keeps the selection.
        #expect(WallNavigation.selection(after: WallChange(before: b, after: nil, index: 1), in: [a, c], selected: a.id) == .keep)
    }
}

private extension WallsCommand {
    var needsEditing: Bool { self == .setTileSize || self == .removeTile || self == .finishEditing }
}
