import Foundation

/// Slowly changing map of how fertile the ground is. Two tileable noise fields are
/// cross-faded over time so that rich regions drift and creatures must follow them.
public final class FertilityField: @unchecked Sendable {
    public static let resolution = 128
    let worldSize: V2
    let a: [Float]
    let b: [Float]

    init(seed: UInt64, worldSize: V2, contrast: Float) {
        self.worldSize = worldSize
        a = FertilityField.makeField(seed: seed &+ 11, contrast: contrast)
        b = FertilityField.makeField(seed: seed &+ 23, contrast: contrast)
    }

    static func makeField(seed: UInt64, contrast: Float) -> [Float] {
        let n = resolution
        var out = [Float](repeating: 0, count: n * n)
        var rng = RNG(seed: seed)
        let octaves: [(Int, Float)] = [(3, 1.0), (6, 0.55), (12, 0.3), (24, 0.12)]
        for (lattice, amp) in octaves {
            var grid = [Float](repeating: 0, count: lattice * lattice)
            for k in 0..<grid.count { grid[k] = rng.float() }
            for y in 0..<n {
                for x in 0..<n {
                    let fx = Float(x) / Float(n) * Float(lattice)
                    let fy = Float(y) / Float(n) * Float(lattice)
                    let x0 = Int(fx), y0 = Int(fy)
                    let tx = fx - Float(x0), ty = fy - Float(y0)
                    let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                    let x1 = (x0 + 1) % lattice, y1 = (y0 + 1) % lattice
                    let v00 = grid[y0 * lattice + x0], v10 = grid[y0 * lattice + x1]
                    let v01 = grid[y1 * lattice + x0], v11 = grid[y1 * lattice + x1]
                    let v = lerp(lerp(v00, v10, sx), lerp(v01, v11, sx), sy)
                    out[y * n + x] += v * amp
                }
            }
        }
        let lo = out.min() ?? 0, hi = out.max() ?? 1
        for k in 0..<out.count {
            let t = (out[k] - lo) / max(hi - lo, 1e-6)
            out[k] = pow(t, contrast)
        }
        return out
    }

    @inline(__always) func sample(_ f: [Float], _ u: Float, _ v: Float) -> Float {
        let n = FertilityField.resolution
        let fx = u * Float(n) - 0.5, fy = v * Float(n) - 0.5
        var x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        x0 = (x0 % n + n) % n; y0 = (y0 % n + n) % n
        let x1 = (x0 + 1) % n, y1 = (y0 + 1) % n
        return lerp(lerp(f[y0 * n + x0], f[y0 * n + x1], tx), lerp(f[y1 * n + x0], f[y1 * n + x1], tx), ty)
    }

    @inline(__always) func blend(time: Float, driftPeriod: Float) -> Float {
        0.5 + 0.5 * sin(2 * .pi * time / driftPeriod)
    }

    /// Fertility in [0, 1] at a world position.
    public func value(at p: V2, time: Float, driftPeriod: Float) -> Float {
        let u = p.x / worldSize.x, v = p.y / worldSize.y
        let w = blend(time: time, driftPeriod: driftPeriod)
        return lerp(sample(a, u, v), sample(b, u, v), w)
    }

    /// The whole map at the given time, row-major, `resolution`² values.
    public func snapshot(time: Float, driftPeriod: Float) -> [Float] {
        let w = blend(time: time, driftPeriod: driftPeriod)
        var out = [Float](repeating: 0, count: a.count)
        for k in 0..<a.count { out[k] = lerp(a[k], b[k], w) }
        return out
    }
}
