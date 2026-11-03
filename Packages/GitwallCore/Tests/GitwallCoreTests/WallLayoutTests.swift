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

    // MARK: Full screen

    /// The sample wall "My day": waiting for my review (large), my pull requests and needs my attention (medium),
    /// failing CI and open bugs (small).
    private let myDay: [TileSize] = [.large, .medium, .small, .small, .medium]

    @Test("full screen takes the columns at which the tiles cover the most of the screen, then the largest scale")
    func fitCoverage() {
        // On an LG UltraFine (3360 × 1890 points, less the margins and the tab bar), five columns give the largest
        // scale but leave a third of the height empty. Four columns, 3 % smaller, fill the whole screen; two and three
        // fill it too, at smaller scales.
        let fit = WallLayout.fit(myDay, width: 3320, height: 1810)
        #expect(fit == WallFit(scale: 1810 / WallLayout.span(3, cell: WallLayout.cellHeight), columns: 4))
        #expect(fit.scale < 3320 / WallLayout.span(5, cell: WallLayout.minimumColumnWidth))
    }

    @Test("a wall that cannot fill the height takes the largest scale at which it fits the width")
    func fitLargestScale() {
        let one = WallLayout.fit([.medium], width: 1000, height: 500)
        #expect(one == WallFit(scale: 1000 / 376, columns: 2))
    }

    @Test("a wall limited by the height gets the fewest columns that reach that scale")
    func fitHeightLimited() {
        // Four and six columns both stack the tiles four cells high; four columns leave no hole.
        let fit = WallLayout.fit([.extraLarge, .large, .large], width: 3320, height: 1810)
        #expect(fit == WallFit(scale: 1810 / WallLayout.span(4, cell: WallLayout.cellHeight), columns: 4))
    }

    @Test("the fitted tiles never stick out of the area and no tile is narrowed, unless the wall is too big for it")
    func fitStaysInside() {
        let walls: [[TileSize]] = [
            myDay, [.extraLarge, .large, .large], [.small], [.extraLarge],
            [.small, .small, .small, .small, .small, .small, .small, .small], [.medium, .large, .extraLarge, .small, .medium],
        ]
        for sizes in walls {
            for (width, height) in [(3320.0, 1810.0), (1960.0, 1180.0), (1200.0, 700.0)] {
                let fit = WallLayout.fit(sizes, width: width, height: height)
                let rects = WallLayout.pack(sizes, columns: fit.columns)
                let fitsHeight = WallLayout.span(WallLayout.rowCount(rects), cell: WallLayout.cellHeight) * fit.scale <= height + 0.001
                guard fitsHeight else {
                    #expect(fit == WallFit(scale: 1, columns: WallLayout.columns(forWidth: width)), "\(sizes) in \(width) × \(height)")
                    continue
                }
                #expect(WallLayout.span(fit.columns, cell: WallLayout.minimumColumnWidth) * fit.scale <= width + 0.001)
                #expect(zip(sizes, rects).allSatisfy { $0.columns == $1.width }, "\(sizes) at \(fit.columns) columns")
                #expect(fit.scale >= 1)
            }
        }
    }

    @Test("a wall too big for the screen keeps its normal size and the window's columns, and scrolls")
    func fitTooBig() {
        let many = Array(repeating: TileSize.extraLarge, count: 40)
        #expect(WallLayout.fit(many, width: 1000, height: 800) == WallFit(scale: 1, columns: 5))
        #expect(WallLayout.fit([], width: 1000, height: 800) == WallFit(scale: 1, columns: 5))
    }

    @Test("zoom scales relative to the fit, and the columns follow the scaled width")
    func fitZoom() {
        let fit = WallLayout.fit(myDay, width: 3320, height: 1810)
        #expect(WallLayout.fit(myDay, width: 3320, height: 1810, zoom: 1) == fit)

        // Twice the fit is 497 points wide before scaling: two columns, as wide as the large tile.
        #expect(WallLayout.fit(myDay, width: 3320, height: 1810, zoom: 2) == WallFit(scale: fit.scale * 2, columns: 2))
        // Three quarters of it is 1326 points wide: six columns.
        #expect(WallLayout.fit(myDay, width: 3320, height: 1810, zoom: 0.75) == WallFit(scale: fit.scale * 0.75, columns: 6))
        // A little closer, the wall that fits in four columns would get a fifth column it leaves empty.
        let team: [TileSize] = [.extraLarge, .large, .large]
        let teamFit = WallLayout.fit(team, width: 3320, height: 1810)
        #expect(WallLayout.fit(team, width: 3320, height: 1810, zoom: 1.25) == WallFit(scale: teamFit.scale * 1.25, columns: 4))
        // An extra large tile keeps its four columns however far in it is zoomed.
        #expect(WallLayout.fit([.extraLarge], width: 1000, height: 500, zoom: 3).columns == 4)
        // A wall too big for the screen zooms as in a window.
        let many = Array(repeating: TileSize.extraLarge, count: 40)
        #expect(WallLayout.fit(many, width: 1000, height: 800, zoom: 2) == WallFit(scale: 2, columns: 4))
    }
}
