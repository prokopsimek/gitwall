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

/// How a full screen wall is drawn: the scale of the grid and the columns its tiles are packed into.
public struct WallFit: Hashable, Sendable {
    public var scale: Double
    public var columns: Int

    public init(scale: Double, columns: Int) {
        self.scale = scale
        self.columns = columns
    }
}

/// Places the tiles of a wall on a grid. The window only turns cells into points.
public enum WallLayout {
    /// The narrowest a column gets before the grid drops one. A cell is then about a small widget.
    public static let minimumColumnWidth = 180.0
    /// The height of a grid row before zoom, about a small widget.
    public static let cellHeight = 170.0
    /// The gap between rows and between columns before zoom.
    public static let spacing = 16.0

    /// Points that `cells` cells of `cell` points take, with the gaps between them.
    public static func span(_ cells: Int, cell: Double) -> Double {
        Double(cells) * cell + Double(max(cells - 1, 0)) * spacing
    }

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

    /// Full screen: the scale and the columns at which the tiles fill an area `width` × `height` points large. Every
    /// column count from the widest tile up is packed, and the largest scale at which the packed tiles fit both the
    /// width, with columns at least ``minimumColumnWidth`` wide, and the height wins; on a tie, the fewer columns. A
    /// wall too big to fit at its normal size keeps that size and the columns of a window (``columns(forWidth:)``),
    /// so it fills the width and scrolls.
    ///
    /// `zoom` (⌘+ and ⌘−) scales relative to the fit. The tiles are then packed into as many columns as the scaled
    /// width holds, never fewer than the widest tile takes, and the columns they leave empty are dropped, so the
    /// tiles still reach across the screen.
    public static func fit(_ sizes: [TileSize], width: Double, height: Double, zoom: Double = 1) -> WallFit {
        guard let fit = bestFit(sizes, width: width, height: height) else {
            return WallFit(scale: zoom, columns: columns(forWidth: width / zoom))
        }
        guard zoom != 1 else { return fit }
        let scale = fit.scale * zoom
        let widest = sizes.map(\.columns).max() ?? 1
        let fitting = max(widest, Int((width / scale + spacing) / (minimumColumnWidth + spacing)))
        let used = pack(sizes, columns: fitting).map { $0.column + $0.width }.max() ?? fitting
        return WallFit(scale: scale, columns: used)
    }

    /// The largest scale of at least 1 at which the packed tiles fit, or nil when there is none.
    private static func bestFit(_ sizes: [TileSize], width: Double, height: Double) -> WallFit? {
        guard let widest = sizes.map(\.columns).max() else { return nil }
        // Past this many columns, a column is narrower than the minimum even at the normal size.
        let most = min(sizes.map(\.columns).reduce(0, +), Int((width + spacing) / (minimumColumnWidth + spacing)))
        guard most >= widest else { return nil }
        var best: WallFit?
        for columns in widest...most {
            let rects = pack(sizes, columns: columns)
            // Tiles that leave columns empty are packed exactly as with fewer columns, which was already tried.
            guard rects.map({ $0.column + $0.width }).max() == columns else { continue }
            let scale = min(
                width / span(columns, cell: minimumColumnWidth),
                height / span(rowCount(rects), cell: cellHeight)
            )
            if scale > best?.scale ?? 0 { best = WallFit(scale: scale, columns: columns) }
        }
        guard let best, best.scale >= 1 else { return nil }
        return best
    }
}
