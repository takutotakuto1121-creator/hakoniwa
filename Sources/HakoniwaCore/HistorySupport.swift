import Foundation
import simd

// Read-only helpers for the time-lapse player. Everything here copies data out of the
// world, so the result can be used on any thread once it has been produced.

/// The slowly changing environment behind a time-lapse: the two fertility fields that are
/// cross-faded over time and the season curve. Immutable values, safe to use off the
/// simulation thread.
public struct HistoryBackdrop: Sendable {
    public var fertilityA: [Float]
    public var fertilityB: [Float]
    public var driftPeriod: Float
    public var seasonPeriod: Float
    public var seasonAmplitude: Float
    public var ticksPerSecond: Float
    public var worldSize: V2

    /// Fertility map (`FertilityField.resolution`² values) at `tick`, written into `out`.
    public func fertility(atTick tick: Double, into out: inout [Float]) {
        let t = Float(tick / Double(ticksPerSecond))
        let w = 0.5 + 0.5 * sin(2 * .pi * t / driftPeriod)
        let n = fertilityA.count
        if out.count != n { out = [Float](repeating: 0, count: n) }
        fertilityA.withUnsafeBufferPointer { a in
            fertilityB.withUnsafeBufferPointer { b in
                out.withUnsafeMutableBufferPointer { o in
                    for k in 0..<n { o[k] = a[k] + (b[k] - a[k]) * w }
                }
            }
        }
    }

    public func season(atTick tick: Double) -> Float {
        let t = Float(tick / Double(ticksPerSecond))
        return 1 + seasonAmplitude * sin(2 * .pi * t / seasonPeriod)
    }
}

extension World {
    public func historyBackdrop() -> HistoryBackdrop {
        HistoryBackdrop(fertilityA: fertility.a, fertilityB: fertility.b, driftPeriod: config.fertilityDriftPeriod,
                        seasonPeriod: config.seasonPeriod, seasonAmplitude: config.seasonAmplitude,
                        ticksPerSecond: config.ticksPerSecond, worldSize: config.worldSize)
    }

    /// A history frame of the present moment (not stored), with every plant included, so a
    /// time-lapse can end exactly on the live world.
    public func presentFrame() -> HistoryFrame {
        var c: [Float16] = []
        c.reserveCapacity(aliveCount * HistoryFrame.stride)
        var carn: Int32 = 0
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue {
            let g = genes[i]
            if g.diet >= 0.65 { carn += 1 }
            c += [Float16(pos[i].x), Float16(pos[i].y), Float16(heading[i]), Float16(rad[i]),
                  Float16(g.hue), Float16(g.saturation), Float16(g.diet), Float16(g.segments),
                  Float16(g.fins), Float16(g.tail), Float16(g.pattern), Float16(g.eyes)]
        }
        var p: [Float16] = []
        p.reserveCapacity(plantCount * 2)
        for f in 0..<foodCount where foodKind[f] == 0 && foodEnergy[f] > 0 {
            p += [Float16(foodPos[f].x), Float16(foodPos[f].y)]
        }
        return HistoryFrame(tick: tick, creatures: c, plants: p, population: Int32(aliveCount),
                            carnivores: carn, maxGeneration: maxGeneration)
    }
}

extension FoodInstance {
    public init(plantAt position: V2, energy: Float) {
        self.init(position: position, energy: energy, kind: 0)
    }
}
