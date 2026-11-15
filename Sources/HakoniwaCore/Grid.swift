import Foundation

/// Uniform spatial hash over a torus, rebuilt every tick with a counting sort.
/// Rebuilding is O(n) and deterministic, which keeps the simulation reproducible.
final class SpatialGrid {
    let cellSize: Float
    let invCell: Float
    let cols: Int
    let rows: Int
    private(set) var cellStart: UnsafeMutablePointer<Int32>
    private(set) var items: UnsafeMutablePointer<Int32>
    /// Per-item data copied into cell order, so neighbour scans read memory sequentially.
    private(set) var packed: UnsafeMutablePointer<SIMD4<Float>>
    private var itemCapacity: Int
    private var cellOf: UnsafeMutablePointer<Int32>

    init(worldSize: V2, cellSize: Float, capacity: Int) {
        self.cols = max(1, Int((worldSize.x / cellSize).rounded(.down)))
        self.rows = max(1, Int((worldSize.y / cellSize).rounded(.down)))
        self.cellSize = worldSize.x / Float(cols)
        self.invCell = 1 / self.cellSize
        cellStart = .allocate(capacity: cols * rows + 1)
        cellStart.initialize(repeating: 0, count: cols * rows + 1)
        itemCapacity = max(capacity, 1)
        items = .allocate(capacity: itemCapacity)
        packed = .allocate(capacity: itemCapacity)
        cellOf = .allocate(capacity: itemCapacity)
    }

    deinit {
        cellStart.deallocate()
        items.deallocate()
        packed.deallocate()
        cellOf.deallocate()
    }

    @inline(__always) func cell(_ p: V2) -> (Int, Int) {
        var cx = Int(p.x * invCell), cy = Int(p.y * invCell)
        if cx >= cols { cx = cols - 1 } else if cx < 0 { cx = 0 }
        if cy >= rows { cy = rows - 1 } else if cy < 0 { cy = 0 }
        return (cx, cy)
    }

    /// Rebuilds the grid from `count` slots. Slots for which `include` is false are skipped.
    func build(count: Int, positions: UnsafePointer<V2>, include: (Int) -> Bool, pack: (Int) -> SIMD4<Float>) {
        if count > itemCapacity {
            items.deallocate(); cellOf.deallocate(); packed.deallocate()
            itemCapacity = count * 2
            items = .allocate(capacity: itemCapacity)
            packed = .allocate(capacity: itemCapacity)
            cellOf = .allocate(capacity: itemCapacity)
        }
        let nCells = cols * rows
        cellStart.update(repeating: 0, count: nCells + 1)
        for i in 0..<count {
            if include(i) {
                let (cx, cy) = cell(positions[i])
                let c = cy * cols + cx
                cellOf[i] = Int32(c)
                cellStart[c + 1] += 1
            } else {
                cellOf[i] = -1
            }
        }
        for c in 0..<nCells { cellStart[c + 1] += cellStart[c] }
        // Fill using a running cursor per cell; iterate in index order so the
        // order within a cell is ascending and deterministic.
        let cursor = UnsafeMutablePointer<Int32>.allocate(capacity: nCells)
        defer { cursor.deallocate() }
        cursor.update(from: cellStart, count: nCells)
        for i in 0..<count {
            let c = Int(cellOf[i])
            if c >= 0 {
                let slot = Int(cursor[c])
                items[slot] = Int32(i)
                packed[slot] = pack(i)
                cursor[c] += 1
            }
        }
    }

    /// Calls `body` with the item range of every cell overlapping the square of half-size `radius`.
    @inline(__always)
    func forEachCell(around p: V2, radius: Float, _ body: (Int, Int) -> Void) {
        let (cx, cy) = cell(p)
        let r = min(Int(radius * invCell) + 1, max(cols, rows) / 2)
        let rx = min(r, (cols - 1) / 2), ry = min(r, (rows - 1) / 2)
        for dy in -ry...ry {
            var y = cy + dy
            if y < 0 { y += rows } else if y >= rows { y -= rows }
            for dx in -rx...rx {
                var x = cx + dx
                if x < 0 { x += cols } else if x >= cols { x -= cols }
                let c = y * cols + x
                let s = Int(cellStart[c]), e = Int(cellStart[c + 1])
                if s < e { body(s, e) }
            }
        }
    }

    /// Visits cells in rings of increasing Chebyshev distance. `body` returns the item range;
    /// after each ring `shouldStop(ringDistance)` is asked whether the search can end, where
    /// ringDistance is a lower bound on the distance of any item in later rings.
    @inline(__always)
    func forEachRing(around p: V2, radius: Float, _ body: (Int, Int) -> Void, shouldStop: (Float) -> Bool) {
        let (cx, cy) = cell(p)
        let maxR = min(Int(radius * invCell) + 1, (min(cols, rows) - 1) / 2)
        // Distance from p to the boundary of its own cell, used for a tight lower bound.
        let lx = p.x - Float(cx) * cellSize, ly = p.y - Float(cy) * cellSize
        let edge = min(min(lx, cellSize - lx), min(ly, cellSize - ly))
        for r in 0...maxR {
            if r == 0 {
                let c = cy * cols + cx
                let s = Int(cellStart[c]), e = Int(cellStart[c + 1])
                if s < e { body(s, e) }
            } else {
                for dy in -r...r {
                    var y = cy + dy
                    if y < 0 { y += rows } else if y >= rows { y -= rows }
                    let full = (dy == -r || dy == r)
                    var dx = -r
                    while dx <= r {
                        var x = cx + dx
                        if x < 0 { x += cols } else if x >= cols { x -= cols }
                        let c = y * cols + x
                        let s = Int(cellStart[c]), e = Int(cellStart[c + 1])
                        if s < e { body(s, e) }
                        dx += full ? 1 : 2 * r
                    }
                }
            }
            let bound = edge + Float(r) * cellSize
            if bound > radius || shouldStop(bound) { return }
        }
    }
}
