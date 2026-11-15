import Foundation
import HakoniwaCore
import simd

/// Turns the coarse time-lapse history (one frame every few minutes of world time) into a
/// smooth picture for any moment in between, packed into a `RenderSnapshot` for the renderer.
///
/// Creatures in the history have no identity across frames (they move far in three minutes),
/// so consecutive frames cross-fade. To make the cross-fade read as motion rather than
/// blinking, every creature glides forward along its heading while it is visible: the old
/// generation swims out of its spot and fades, the new one swims into place.
final class HistoryPlayback {
    let frames: [HistoryFrame]
    let backdrop: HistoryBackdrop
    /// World seconds of each frame.
    let times: [Double]
    let snapshot = RenderSnapshot()
    /// How many on-screen plants each recorded plant stands for (history keeps a subsample).
    private let plantCopies: [Int]
    private var decoded: [Int: [CreatureInstance]] = [:]
    private var decodeOrder: [Int] = []
    private var fertility: [Float] = []

    /// Distance (world units) a creature glides while it fades in or out.
    static let glide: Float = 46

    init(frames: [HistoryFrame], backdrop: HistoryBackdrop, referencePlants: Int?) {
        self.frames = frames
        self.backdrop = backdrop
        let tps = Double(backdrop.ticksPerSecond)
        times = frames.map { Double($0.tick) / tps }
        // The history stores at most ~3000 plants per frame. Restore the visual density by
        // drawing a few scattered copies of each, matched to the full count of the present frame.
        let full = referencePlants ?? 0
        plantCopies = frames.map { f in
            let n = f.plants.count / 2
            guard n >= 1200, full > n else { return 1 }
            return min(8, max(1, Int((Double(full) / Double(n)).rounded())))
        }
        snapshot.worldSize = backdrop.worldSize
        snapshot.ticksPerSecond = backdrop.ticksPerSecond
    }

    var startTime: Double { times.first ?? 0 }
    var endTime: Double { times.last ?? 0 }

    /// Index of the frame at or before `t` and the fraction towards the next one.
    func segment(at t: Double) -> (Int, Float) {
        guard times.count > 1 else { return (0, 0) }
        if t <= times[0] { return (0, 0) }
        if t >= times[times.count - 1] { return (times.count - 1, 0) }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = max(times[hi] - times[lo], 1e-6)
        return (lo, Float((t - times[lo]) / span))
    }

    /// Interpolated headline numbers at `t`.
    func stats(at t: Double) -> (population: Int, carnivores: Int, generation: Int) {
        let (i, f) = segment(at: t)
        let a = frames[i]
        guard i + 1 < frames.count else { return (Int(a.population), Int(a.carnivores), Int(a.maxGeneration)) }
        let b = frames[i + 1]
        func mix(_ x: Int32, _ y: Int32) -> Int { Int((Float(x) + (Float(y) - Float(x)) * f).rounded()) }
        return (mix(a.population, b.population), mix(a.carnivores, b.carnivores), mix(a.maxGeneration, b.maxGeneration))
    }

    private func creatures(_ i: Int) -> [CreatureInstance] {
        if let c = decoded[i] { return c }
        let f = frames[i]
        let c = (0..<f.creatureCount).map { f.instance($0) }
        decoded[i] = c
        decodeOrder.append(i)
        if decodeOrder.count > 6 { decoded[decodeOrder.removeFirst()] = nil }
        return c
    }

    @inline(__always) private func wrap(_ p: V2) -> V2 {
        let s = backdrop.worldSize
        return V2(p.x - s.x * (p.x / s.x).rounded(.down), p.y - s.y * (p.y / s.y).rounded(.down))
    }

    @inline(__always) private static func hash(_ k: Int, _ salt: UInt32) -> Float {
        var x = UInt32(truncatingIfNeeded: k) &* 0x9E37_79B1 ^ salt
        x ^= x >> 15; x = x &* 0x2C1B_3C6D; x ^= x >> 12; x = x &* 0x297A_2D39; x ^= x >> 15
        return Float(x >> 8) / Float(1 << 24)
    }

    @inline(__always) private static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Fills `snapshot` for world time `t`. `wall` drives the swimming animation.
    func fill(at t: Double, wall: Double) -> RenderSnapshot {
        let (i, f) = segment(at: t)
        let snap = snapshot
        snap.creatures.removeAll(keepingCapacity: true)
        snap.uids.removeAll(keepingCapacity: true)
        snap.food.removeAll(keepingCapacity: true)
        snap.fx.removeAll(keepingCapacity: true)
        let tick = t * Double(backdrop.ticksPerSecond)
        snap.tick = Int64(tick)
        snap.season = backdrop.season(atTick: tick)
        backdrop.fertility(atTick: tick, into: &fertility)
        snap.fertility = fertility
        // Negative and unique per frame: always re-uploaded, never mistaken for a live snapshot.
        snap.fertilityTick = -1000 - Int64(tick)

        let hasNext = i + 1 < frames.count && f > 0
        let blend = hasNext ? HistoryPlayback.smooth(0.08, 0.92, f) : 0
        let swim = Float(wall.truncatingRemainder(dividingBy: 1000)) * 7
        addCreatures(i, alpha: 1 - blend, glide: hasNext ? f : 0, swim: swim, into: snap)
        if hasNext { addCreatures(i + 1, alpha: blend, glide: f - 1, swim: swim, into: snap) }
        addPlants(i, keep: { $0 >= blend }, into: snap)
        if hasNext { addPlants(i + 1, keep: { $0 < blend }, into: snap) }
        return snap
    }

    private func addCreatures(_ i: Int, alpha: Float, glide g: Float, swim: Float, into snap: RenderSnapshot) {
        guard alpha > 0.015 else { return }
        let src = creatures(i)
        let fade = 1 - min(alpha, 1)
        snap.creatures.reserveCapacity(snap.creatures.count + src.count)
        for var c in src {
            let dir = V2(cos(c.heading), sin(c.heading))
            c.position = wrap(c.position + dir * (HistoryPlayback.glide * g))
            c.velocity = dir * 30
            c.radius *= 0.72 + 0.28 * alpha
            c.swimPhase += swim
            // Integer flag bits stay 0 (adult, idle); the fraction is the fade-out amount.
            c.flags = fade >= 0.999 ? 0.999 : fade
            snap.creatures.append(c)
        }
    }

    private func addPlants(_ i: Int, keep: (Float) -> Bool, into snap: RenderSnapshot) {
        let p = frames[i].plants
        let n = p.count / 2
        let copies = plantCopies[i]
        snap.food.reserveCapacity(snap.food.count + n * copies)
        p.withUnsafeBufferPointer { pp in
            for k in 0..<n {
                let base = V2(Float(pp[2 * k]), Float(pp[2 * k + 1]))
                for j in 0..<copies {
                    // Stable per-plant dissolve threshold, so plants appear and vanish one by one.
                    let id = k &* 8 &+ j
                    guard keep(HistoryPlayback.hash(id, 0x51ED_270B)) else { continue }
                    var q = base
                    if j > 0 {
                        let a = HistoryPlayback.hash(id, 0x1B87_3593) * 2 * .pi
                        let r = 18 + HistoryPlayback.hash(id, 0xCC9E_2D51) * 62
                        q = wrap(base + V2(cos(a), sin(a)) * r)
                    }
                    let e = 26 + HistoryPlayback.hash(id, 0x85EB_CA6B) * 14
                    snap.food.append(FoodInstance(plantAt: q, energy: e))
                }
            }
        }
    }
}
