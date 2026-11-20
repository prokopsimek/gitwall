import Foundation
import Testing
@testable import GitwallCore

@Suite("Presets a regular sync fetches")
struct SyncSelectionTests {
    let review = Preset(name: "Waiting for my review")
    let blockers = Preset(name: "Release blockers", kinds: [.issue])
    let docs = Preset(name: "Docs pull requests")
    let flaky = Preset(name: "Flaky CI")

    // MARK: - Desktop widgets

    @Test("a widget with a preset selects that preset and nothing else")
    func widgetWithPreset() {
        let config = AppConfig(presets: [review, blockers, docs])
        let selection = SyncSelection.presets(in: config, widgets: [blockers.id], open: [], shownWall: nil)
        #expect(selection.presetIDs == [blockers.id])
        #expect(selection.widgets == [blockers.id])
    }

    @Test("a widget without a preset shows the first preset, so the first preset is selected")
    func widgetWithoutPreset() {
        let config = AppConfig(presets: [review, blockers])
        let selection = SyncSelection.presets(in: config, widgets: [nil], open: [], shownWall: nil)
        #expect(selection.presetIDs == [review.id])
        #expect(selection.widgets == [review.id])
    }

    @Test("a widget whose preset was deleted shows the first preset, so the first preset is selected")
    func widgetWithDeletedPreset() {
        let deleted = UUID()
        let config = AppConfig(presets: [review, blockers])
        let selection = SyncSelection.presets(in: config, widgets: [deleted], open: [], shownWall: nil)
        #expect(selection.presetIDs == [review.id])
        #expect(selection.widgets == [review.id])
    }

    @Test("without any preset a widget shows nothing, so nothing is selected")
    func noPresets() {
        let config = AppConfig(presets: [])
        let selection = SyncSelection.presets(in: config, widgets: [nil, UUID()], open: [UUID()], shownWall: nil)
        #expect(selection.presetIDs.isEmpty)
        #expect(selection.widgets.isEmpty)
    }

    // MARK: - Menu bar and notifications

    @Test("the preset whose count is in the menu bar is selected")
    func menuBar() {
        var counted = blockers
        counted.showCountInMenuBar = true
        let config = AppConfig(presets: [review, counted, docs])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: nil)
        #expect(selection.presetIDs == [counted.id])
        #expect(selection.menuBar == [counted.id])
    }

    @Test("when several presets ask for the menu bar count, only the first one is counted there, so only it is selected")
    func menuBarFirstOnly() {
        var first = blockers
        first.showCountInMenuBar = true
        var second = docs
        second.showCountInMenuBar = true
        let config = AppConfig(presets: [review, first, second])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: nil)
        #expect(selection.presetIDs == [first.id])
        #expect(selection.menuBar == [first.id])
    }

    @Test("every preset with at least one notification switched on is selected")
    func notifications() {
        var merged = review
        merged.notifications = [.merged]
        var failing = flaky
        failing.notifications = [.ciFailed, .closed]
        let config = AppConfig(presets: [merged, blockers, failing])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: nil)
        #expect(selection.presetIDs == [merged.id, failing.id])
        #expect(selection.notifications == [merged.id, failing.id])
    }

    @Test("with no widget on the desktop only the menu bar and notification presets are selected")
    func emptyDesktop() {
        var counted = review
        counted.showCountInMenuBar = true
        var notifying = docs
        notifying.notifications = [.newItem]
        let config = AppConfig(presets: [counted, blockers, notifying, flaky])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: nil)
        #expect(selection.presetIDs == [counted.id, notifying.id])
        #expect(selection.widgets.isEmpty)
        #expect(selection.menuBar == [counted.id])
        #expect(selection.notifications == [notifying.id])
    }

    // MARK: - Popover, main window and Walls window

    @Test("the presets open in the popover and the main window are selected")
    func openInWindows() {
        let config = AppConfig(presets: [review, blockers, docs])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [docs.id, review.id], shownWall: nil)
        #expect(selection.presetIDs == [review.id, docs.id])
        #expect(selection.windows == [review.id, docs.id])
    }

    @Test("an open preset that no longer exists selects nothing")
    func openDeletedPreset() {
        let config = AppConfig(presets: [review, blockers])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [UUID()], shownWall: nil)
        #expect(selection.presetIDs.isEmpty)
        #expect(selection.windows.isEmpty)
    }

    @Test("the wall the Walls window shows selects the presets of its tiles, and no other wall counts")
    func shownWall() {
        let shown = Wall(name: "Team monitor", tiles: [Tile(presetID: flaky.id, size: .large), Tile(presetID: blockers.id)])
        let other = Wall(name: "Docs corner", tiles: [Tile(presetID: docs.id)])
        let config = AppConfig(presets: [review, blockers, docs, flaky], walls: [other, shown])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: shown.id)
        #expect(selection.presetIDs == [blockers.id, flaky.id])
        #expect(selection.wall == [blockers.id, flaky.id])
    }

    @Test("a tile whose preset was deleted stays on the wall but selects nothing")
    func tileWithDeletedPreset() {
        let shown = Wall(name: "Team monitor", tiles: [Tile(presetID: UUID()), Tile(presetID: review.id)])
        let config = AppConfig(presets: [review, blockers], walls: [shown])
        let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: shown.id)
        #expect(selection.presetIDs == [review.id])
        #expect(selection.wall == [review.id])
    }

    @Test("a wall id that names no wall, or a closed Walls window, selects nothing for walls")
    func unknownOrNoWall() {
        let wall = Wall(name: "Team monitor", tiles: [Tile(presetID: review.id)])
        let config = AppConfig(presets: [review, blockers], walls: [wall])
        for shownWall in [UUID(), nil] {
            let selection = SyncSelection.presets(in: config, widgets: [], open: [], shownWall: shownWall)
            #expect(selection.presetIDs.isEmpty)
            #expect(selection.wall.isEmpty)
        }
    }

    // MARK: - All sources together

    @Test("a preset used by several sources is selected once and counted by each of them")
    func duplicatesAcrossSources() {
        var shared = review
        shared.showCountInMenuBar = true
        shared.notifications = [.reviewRequested]
        let wall = Wall(name: "Team monitor", tiles: [Tile(presetID: shared.id), Tile(presetID: docs.id)])
        let config = AppConfig(presets: [blockers, shared, docs, flaky], walls: [wall])
        let selection = SyncSelection.presets(
            in: config, widgets: [shared.id, shared.id, nil], open: [shared.id], shownWall: wall.id
        )
        #expect(selection.presetIDs == [blockers.id, shared.id, docs.id])
        #expect(selection.widgets == [shared.id, blockers.id])
        #expect(selection.menuBar == [shared.id])
        #expect(selection.notifications == [shared.id])
        #expect(selection.windows == [shared.id])
        #expect(selection.wall == [shared.id, docs.id])
    }

    @Test("a preset that no widget, window, menu bar or notification uses is not selected")
    func presetInNoSource() {
        let config = AppConfig(presets: [review, blockers, docs, flaky])
        let selection = SyncSelection.presets(in: config, widgets: [docs.id, review.id], open: [], shownWall: nil)
        #expect(selection.presetIDs == [review.id, docs.id])
        #expect(!selection.presetIDs.contains(blockers.id))
        #expect(!selection.presetIDs.contains(flaky.id))
    }
}
