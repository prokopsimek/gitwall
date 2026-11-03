import Foundation
import Testing
@testable import GitwallCore

@Suite("Wall layout")
struct WallLayoutTests {
    private func rect(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> GridRect {
        GridRect(column: column, row: row, width: width, height: height)
    }

    @Test("tiles fill rows from the top left in their order")
    func order() {
        let rects = WallLayout.pack([.medium, .small, .small, .large], columns: 4)
        #expect(rects == [rect(0, 0, 2, 1), rect(2, 0, 1, 1), rect(3, 0, 1, 1), rect(0, 1, 2, 2)])
        #expect(WallLayout.rowCount(rects) == 3)
    }

    @Test("a later tile fills a gap an earlier one left, if it fits")
    func gaps() {
        let rects = WallLayout.pack([.large, .extraLarge, .small, .medium], columns: 4)
        // The extra large tile does not fit beside the large one and goes below it; the small and medium ones then
        // take the space the large one left free.
        #expect(rects == [rect(0, 0, 2, 2), rect(0, 2, 4, 2), rect(2, 0, 1, 1), rect(2, 1, 2, 1)])
        #expect(WallLayout.rowCount(rects) == 4)
    }

    @Test("a tile wider than the grid is narrowed to the number of columns")
    func narrow() {
        #expect(WallLayout.pack([.extraLarge, .medium], columns: 2) == [rect(0, 0, 2, 2), rect(0, 2, 2, 1)])
        #expect(WallLayout.pack([.extraLarge, .small], columns: 1) == [rect(0, 0, 1, 2), rect(0, 2, 1, 1)])
        #expect(WallLayout.pack([.medium], columns: 0) == [rect(0, 0, 1, 1)])
    }

    @Test("the same tiles always give the same layout, and no two tiles overlap")
    func deterministic() {
        let sizes: [TileSize] = [.small, .extraLarge, .medium, .large, .small, .small, .medium, .large, .small, .extraLarge]
        let rects = WallLayout.pack(sizes, columns: 6)
        #expect(rects == WallLayout.pack(sizes, columns: 6))
        var cells = Set<[Int]>()
        for rect in rects {
            #expect(rect.column + rect.width <= 6)
            for column in rect.column..<(rect.column + rect.width) {
                for row in rect.row..<(rect.row + rect.height) {
                    #expect(cells.insert([column, row]).inserted)
                }
            }
        }
    }

    @Test("an empty wall has no rows")
    func empty() {
        #expect(WallLayout.pack([], columns: 4).isEmpty)
        #expect(WallLayout.rowCount([]) == 0)
    }

    @Test("zoom steps through fixed levels and stops at the smallest and the largest")
    func zoom() {
        #expect(WallLayout.zoom(1, step: 1) == 1.25)
        #expect(WallLayout.zoom(1, step: -1) == 0.75)
        #expect(WallLayout.zoom(3, step: 1) == 3)
        #expect(WallLayout.zoom(0.75, step: -1) == 0.75)
        // A value between two levels goes to the next one in that direction.
        #expect(WallLayout.zoom(1.1, step: 1) == 1.25)
        #expect(WallLayout.zoom(1.1, step: -1) == 1)
        #expect(WallLayout.zoomLevels.contains(1))
    }

    @Test("a column is at least 180 points wide, and there are never fewer than four")
    func columns() {
        #expect(WallLayout.columns(forWidth: 400) == 4)
        #expect(WallLayout.columns(forWidth: 720) == 4)
        #expect(WallLayout.columns(forWidth: 1100) == 6)
        #expect(WallLayout.columns(forWidth: 2560) == 14)
    }
}
