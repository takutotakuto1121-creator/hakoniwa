import Foundation
import simd

// Read-only helpers for the app's "god hand" features (walls, climate, plague).
// Nothing here changes the simulation; it only exposes state for drawing.

extension CreatureInstance {
    /// Bit in `flags` marking a creature that is currently ill (set by `World.markSickness`).
    public static let sickFlag: Float = 16
}

extension World {
    /// Number of living creatures that are currently ill.
    public var sickCount: Int {
        var n = 0
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue && sick[i] > 0 { n += 1 }
        return n
    }

    /// Adds `CreatureInstance.sickFlag` to the flags of every ill creature in `snap`.
    /// Must be called right after `fillRender(snap)` (it relies on the same slot order).
    /// Returns the number of ill creatures.
    @discardableResult
    public func markSickness(_ snap: RenderSnapshot) -> Int {
        var k = 0, n = 0
        let total = snap.creatures.count
        for i in 0..<highWater where stage[i] != 0 {
            guard k < total else { break }
            if stage[i] == Stage.alive.rawValue && sick[i] > 0 {
                snap.creatures[k].flags += CreatureInstance.sickFlag
                n += 1
            }
            k += 1
        }
        return n
    }

    /// Seconds left in the current climate event (0 when the climate is normal).
    public var climateRemainingSeconds: Double {
        climate.kind == .normal ? 0 : Double(max(climate.remainingTicks, 0)) / Double(config.ticksPerSecond)
    }
}

extension WallMask {
    /// Signed distance to the wall boundary for every cell, in cells
    /// (negative inside walls, positive outside), clamped to ±`maxDistance`.
    /// The grid wraps around like the world.
    public func signedDistanceField(maxDistance: Int = 6) -> [Float] {
        let n = WallMask.resolution
        let m = Float(maxDistance)
        guard count > 0 else { return [Float](repeating: m, count: n * n) }
        // Offsets within the search radius, nearest first.
        var offsets: [(Int, Int, Float)] = []
        for dy in -maxDistance...maxDistance {
            for dx in -maxDistance...maxDistance {
                let d = Float(dx * dx + dy * dy).squareRoot()
                if d <= m && (dx != 0 || dy != 0) { offsets.append((dx, dy, d)) }
            }
        }
        offsets.sort { $0.2 < $1.2 }
        var out = [Float](repeating: m, count: n * n)
        cells.withUnsafeBufferPointer { c in
            for y in 0..<n {
                for x in 0..<n {
                    let inside = c[y * n + x] != 0
                    var best = m + 0.5
                    for (dx, dy, d) in offsets {
                        let xx = (x + dx + n) % n, yy = (y + dy + n) % n
                        if (c[yy * n + xx] != 0) != inside { best = d; break }
                    }
                    let s = min(best - 0.5, m)
                    out[y * n + x] = inside ? -s : s
                }
            }
        }
        return out
    }
}

extension World {
    /// Moves creatures and eggs that ended up inside a wall to the nearest open cell
    /// (painting a wall on top of them would otherwise trap them). Returns how many moved.
    @discardableResult
    public func evictFromWalls() -> Int {
        guard walls.count > 0 else { return 0 }
        let n = WallMask.resolution
        let cw = config.worldWidth / Float(n), ch = config.worldHeight / Float(n)
        var moved = 0
        for i in 0..<highWater where stage[i] != 0 && walls.isWall(pos[i]) {
            let cx = Int(pos[i].x / cw), cy = Int(pos[i].y / ch)
            var best: V2?
            var bestD = Float.greatestFiniteMagnitude
            for r in 1...(n / 2) {
                for dy in -r...r {
                    for dx in -r...r where max(abs(dx), abs(dy)) == r {
                        let x = ((cx + dx) % n + n) % n, y = ((cy + dy) % n + n) % n
                        guard walls.cells[y * n + x] == 0 else { continue }
                        let c = V2((Float(cx + dx) + 0.5) * cw, (Float(cy + dy) + 0.5) * ch)
                        let d = simd_length(c - pos[i])
                        if d < bestD { bestD = d; best = c }
                    }
                }
                if best != nil { break }
            }
            guard let p = best else { continue }
            pos[i] = torusWrap(p, config.worldSize)
            vel[i] = .zero
            moved += 1
        }
        return moved
    }
}

extension World {
    /// Splits the world into two continents with two full-height walls.
    /// `splitContinents()` paints each wall as one top-to-bottom line, which `paintWall` wraps
    /// around the torus into a line only one unit long, so the walls are painted here in short
    /// segments first; `splitContinents()` then logs the event and pushes creatures out.
    public func splitIntoContinents(radius: Float = 50) {
        let w = config.worldWidth, h = config.worldHeight
        let segments = 48
        for (n, x) in [Float(2), w / 2].enumerated() {
            // A gently meandering ridge; whole periods so it closes up across the top/bottom edge.
            func at(_ k: Int) -> V2 {
                let t = Float(k) / Float(segments) * 2 * .pi
                let dx = sin(t * 2 + Float(n) * 2.1) * w * 0.03 + sin(t * 5 + Float(n)) * w * 0.012
                return V2(x + dx, h * Float(k) / Float(segments))
            }
            for k in 0..<segments {
                paintWall(from: at(k), to: at(k + 1), radius: radius)
            }
        }
        splitContinents()
        evictFromWalls()
    }
}
