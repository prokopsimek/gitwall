import Foundation

/// Where a tile sits on the grid of a wall, in cells from the top left.
public struct GridRect: Hashable, Sendable {
    public var column: Int
    public var row: Int
    public var width: Int
    public var height: Int

    public init(column: Int, row: Int, width: Int, height: Int) {
        self.column = column
        self.row = row
        self.width = width
        self.height = height
    }
}

/// Places the tiles of a wall on a grid. The window only turns cells into points.
public enum WallLayout {
    /// The narrowest a column gets before the grid drops one. A cell is then about a small widget.
    public static let minimumColumnWidth = 180.0

    /// Columns for a grid `width` points wide: as many 180-point columns as fit, and never fewer than four, so an
    /// extra large tile always fits next to nothing else rather than being narrowed.
    public static func columns(forWidth width: Double) -> Int {
        max(4, Int(width / minimumColumnWidth))
    }

    /// First fit: each tile, in order, goes to the topmost and then leftmost free place it fits, so a later small
    /// tile fills a gap an earlier large one left. The same tiles always give the same layout. A tile wider than
    /// the grid is narrowed to its width.
    public static func pack(_ sizes: [TileSize], columns: Int) -> [GridRect] {
        let columns = max(columns, 1)
        var occupied: [[Bool]] = []
        func isFree(column: Int, row: Int, width: Int, height: Int) -> Bool {
            for y in row..<(row + height) where y < occupied.count {
                for x in column..<(column + width) where occupied[y][x] {
                    return false
                }
            }
            return true
        }

        return sizes.map { size -> GridRect in
            let width = min(size.columns, columns)
            let height = size.rows
            var row = 0
            while true {
                for column in 0...(columns - width) where isFree(column: column, row: row, width: width, height: height) {
                    while occupied.count < row + height { occupied.append(Array(repeating: false, count: columns)) }
                    for y in row..<(row + height) {
                        for x in column..<(column + width) { occupied[y][x] = true }
                    }
                    return GridRect(column: column, row: row, width: width, height: height)
                }
                row += 1
            }
        }
    }

    /// Zoom In and Zoom Out step through these, so a wall on a large monitor can be read from across the room.
    public static let zoomLevels: [Double] = [0.75, 1, 1.25, 1.5, 2, 2.5, 3]

    /// The next level up (`step` > 0) or down from `current`, staying at the ends.
    public static func zoom(_ current: Double, step: Int) -> Double {
        if step > 0 { return zoomLevels.first { $0 > current } ?? zoomLevels.last ?? current }
        if step < 0 { return zoomLevels.last { $0 < current } ?? zoomLevels.first ?? current }
        return current
    }

    /// Rows the packed tiles take, for the height of the grid.
    public static func rowCount(_ rects: [GridRect]) -> Int {
        rects.map { $0.row + $0.height }.max() ?? 0
    }
}
