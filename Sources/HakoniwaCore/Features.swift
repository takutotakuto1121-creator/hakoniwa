import Foundation
import simd

// MARK: - Walls (continental drift / barriers)

/// Coarse occupancy grid of impassable terrain painted by the player.
public final class WallMask: @unchecked Sendable {
    public static let resolution = 128
    public private(set) var cells: [UInt8]
    public private(set) var version = 0
    public private(set) var count = 0
    let worldSize: V2
    let inv: V2

    init(worldSize: V2) {
        self.worldSize = worldSize
        inv = V2(Float(WallMask.resolution), Float(WallMask.resolution)) / worldSize
        cells = [UInt8](repeating: 0, count: WallMask.resolution * WallMask.resolution)
    }

    @inline(__always) func index(_ p: V2) -> Int {
        let n = WallMask.resolution
        var x = Int(p.x * inv.x), y = Int(p.y * inv.y)
        if x < 0 { x = 0 } else if x >= n { x = n - 1 }
        if y < 0 { y = 0 } else if y >= n { y = n - 1 }
        return y * n + x
    }

    @inline(__always) public func isWall(_ p: V2) -> Bool { count > 0 && cells[index(p)] != 0 }

    func set(_ cx: Int, _ cy: Int, _ v: UInt8) {
        let n = WallMask.resolution
        let x = (cx % n + n) % n, y = (cy % n + n) % n
        let k = y * n + x
        if cells[k] != v {
            count += v != 0 ? 1 : -1
            cells[k] = v
        }
    }

    func load(_ c: [UInt8]) {
        guard c.count == cells.count else { return }
        cells = c
        count = c.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        version += 1
    }

    func touch() { version += 1 }
}

extension World {
    /// Paints (or erases) a thick line of wall between two world points.
    public func paintWall(from a: V2, to b: V2, radius: Float, erase: Bool = false) {
        let n = WallMask.resolution
        let cell = config.worldWidth / Float(n)
        let d = torusDelta(b - a, config.worldSize)
        let steps = max(1, Int(simd_length(d) / (cell * 0.5)))
        let r = max(0, Int((radius / cell).rounded()))
        for s in 0...steps {
            let p = torusWrap(a + d * (Float(s) / Float(steps)), config.worldSize)
            let cx = Int(p.x / cell), cy = Int(p.y / cell)
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy <= r * r + r {
                    walls.set(cx + dx, cy + dy, erase ? 0 : 1)
                }
            }
        }
        walls.touch()
        if !erase { removeFoodInWalls() }
    }

    /// Splits the torus into two separate continents with two vertical walls.
    public func splitContinents() {
        let w = config.worldWidth, h = config.worldHeight
        for x in [Float(2), w / 2] {
            paintWall(from: V2(x, 0), to: V2(x, h - 1), radius: 40)
            paintWall(from: V2(x, h - 1), to: V2(x, 0), radius: 40)
        }
        // Push creatures that ended up inside the wall out of it.
        for i in 0..<highWater where stage[i] != 0 && walls.isWall(pos[i]) {
            pos[i] = torusWrap(pos[i] + V2(90, 0), config.worldSize)
        }
        log(.intervention, "大陸が二つに分断された")
    }

    public func clearWalls() {
        guard walls.count > 0 else { return }
        walls.load([UInt8](repeating: 0, count: WallMask.resolution * WallMask.resolution))
        log(.intervention, "壁が取り払われ、分かれていた大地がつながった")
    }

    func removeFoodInWalls() {
        var changed = false
        for k in 0..<foodCount where foodEnergy[k] > 0 && walls.isWall(foodPos[k]) {
            soil += foodEnergy[k]
            foodEnergy[k] = 0
            if foodKind[k] == 0 { plantCount -= 1 } else { meatCount -= 1 }
            changed = true
        }
        if changed { compactFood() }
    }

    /// Moves from `p` by `delta`, sliding along walls instead of entering them.
    @inline(__always) func moveRespectingWalls(_ p: V2, _ delta: V2) -> (V2, Bool) {
        let size = config.worldSize
        let full = torusWrap(p + delta, size)
        if !walls.isWall(full) { return (full, false) }
        let xOnly = torusWrap(p + V2(delta.x, 0), size)
        if !walls.isWall(xOnly) { return (xOnly, true) }
        let yOnly = torusWrap(p + V2(0, delta.y), size)
        if !walls.isWall(yOnly) { return (yOnly, true) }
        return (p, true)
    }
}

// MARK: - Climate events and plague

public enum ClimateKind: Int, Codable, Sendable {
    case normal, iceAge, bloom
    public var label: String {
        switch self {
        case .normal: return "平常"
        case .iceAge: return "氷河期"
        case .bloom: return "温暖期"
        }
    }
}

public struct ClimateState: Codable, Sendable {
    public var kind: ClimateKind = .normal
    public var remainingTicks: Int64 = 0
    public var plantMultiplier: Float {
        switch kind {
        case .normal: return 1
        case .iceAge: return 0.22
        case .bloom: return 2.2
        }
    }
}

extension World {
    public func startClimate(_ kind: ClimateKind, minutes: Float) {
        climate = ClimateState(kind: kind, remainingTicks: Int64(minutes * 60 * config.ticksPerSecond))
        switch kind {
        case .iceAge: log(.intervention, "氷河期が始まった(植物が激減する)")
        case .bloom: log(.intervention, "温暖期が始まった(植物が豊かに茂る)")
        case .normal: log(.intervention, "気候が平常に戻った")
        }
    }

    func updateClimate() {
        guard climate.kind != .normal else { return }
        climate.remainingTicks -= 1
        if climate.remainingTicks <= 0 {
            let ended = climate.kind
            climate = ClimateState()
            log(.milestone, "\(ended.label)が終わった")
        }
    }

    /// A disease strikes the most populous established species. Each infected member
    /// falls ill for a while; most of them die.
    @discardableResult
    public func plague() -> String? {
        guard let target = species.filter({ $0.established && $0.population > 0 }).max(by: { $0.population < $1.population }) else { return nil }
        var infected = 0
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue && speciesOf[i] == target.id {
            if rng.chance(0.8) {
                sick[i] = rng.float(5, 45)
                infected += 1
            }
        }
        log(.intervention, "疫病が「\(target.name)」を襲った(\(infected)匹が感染)", target.id)
        return target.name
    }

    func progressSickness(_ i: Int) -> Bool {
        guard sick[i] > 0 else { return false }
        sick[i] -= config.dt
        if sick[i] <= 0 {
            sick[i] = 0
            return rng.chance(0.7)
        }
        return false
    }
}

// MARK: - Reviving extinct ancestors

extension World {
    /// Brings back the founder of a species (alive or extinct) near a point.
    @discardableResult
    public func revive(speciesId: Int32, at p: V2, count: Int = 6) -> [UInt64] {
        guard speciesId >= 0, Int(speciesId) < species.count else { return [] }
        let rec = species[Int(speciesId)]
        let wasExtinct = rec.population == 0
        var out: [UInt64] = []
        for k in 0..<count {
            var g = rec.founderGenes
            var b = rec.founderBrain
            if k > 0 { g.mutate(&rng); BrainOps.mutate(&b, rate: 0.2, &rng) }
            let e = Phenotype(g, config).capacityAdult * 0.6
            let at = torusWrap(p + V2(rng.gaussian(), rng.gaussian()) * 40, config.worldSize)
            guard soil > e * 2, !walls.isWall(at),
                  let i = spawn(genes: g, brain: b, at: at, energy: e, asEgg: false, species: speciesId,
                                parent: -1, generation: rec.maxGeneration) else { continue }
            soil -= e
            age[i] = config.maturityAge
            rad[i] = radius(i)
            health[i] = maxHealth(i)
            body[i] = config.bodyPerMass * rad[i] * rad[i]
            soil -= body[i]
            if collectFX { fx(.birth, i) }
            out.append(uid[i])
        }
        if !out.isEmpty {
            rec.extinctTick = nil
            let ago = formatDuration(Double(tick - rec.birthTick) / Double(config.ticksPerSecond))
            log(.intervention, wasExtinct ? "絶滅した「\(rec.name)」が蘇った(\(ago)前の祖先)" : "「\(rec.name)」の祖先型を\(out.count)匹放った", rec.id)
        }
        return out
    }
}

// MARK: - Biography of a watched creature

public struct BioEntry: Sendable, Identifiable {
    public var id: Int
    public var tick: Int64
    public var text: String
}

extension World {
    /// Starts recording the life story of a creature. Pass 0 to stop.
    public func watch(uid u: UInt64) {
        guard u != watchUid else { return }
        watchUid = u
        biography.removeAll()
        bioFlags = []
        guard let i = slot(of: u) else { return }
        let sp = speciesOf[i] >= 0 ? species[Int(speciesOf[i])].name : "不明な種"
        let stageText = stage[i] == Stage.egg.rawValue ? "卵" : "\(formatDuration(Double(age[i])))生きた個体"
        bio(i, "観察開始。「\(sp)」の第\(generation[i])世代、\(stageText)。")
    }

    @inline(__always) func isWatched(_ i: Int) -> Bool { watchUid != 0 && uid[i] == watchUid }

    func bio(_ i: Int, _ text: String) {
        biography.append(BioEntry(id: biography.count, tick: tick, text: text))
        if biography.count > 300 { biography.removeFirst(biography.count - 300) }
    }

    func speciesName(_ i: Int) -> String {
        let s = speciesOf[i]
        return s >= 0 && Int(s) < species.count ? species[Int(s)].name : "未知の生き物"
    }

    func bioAte(_ i: Int, meat: Bool) {
        if meat && !bioFlags.contains(.firstMeat) {
            bioFlags.insert(.firstMeat)
            bio(i, "初めて肉を口にした。")
        } else if !meat && !bioFlags.contains(.firstPlant) {
            bioFlags.insert(.firstPlant)
            bio(i, "初めて植物を食べた。")
        }
    }

    func bioBitten(victim i: Int, by a: Int) {
        guard tick - lastBioBitten > Int64(config.ticksPerSecond * 4) else { return }
        lastBioBitten = tick
        bio(i, "「\(speciesName(a))」に噛みつかれた!(体力 \(Int(max(health[i], 0)))/\(Int(maxHealth(i))))")
    }

    func bioBit(attacker i: Int, victim t: Int) {
        guard tick - lastBioBite > Int64(config.ticksPerSecond * 4) else { return }
        lastBioBite = tick
        bio(i, "「\(speciesName(t))」に襲いかかった。")
    }
}

struct BioFlags: OptionSet {
    let rawValue: Int
    static let firstPlant = BioFlags(rawValue: 1)
    static let firstMeat = BioFlags(rawValue: 2)
}

// MARK: - Hall of fame

public enum FameKind: Int, CaseIterable, Codable, Sendable {
    case kills, offspring, longevity
    public var label: String {
        switch self {
        case .kills: return "捕食数"
        case .offspring: return "子の数"
        case .longevity: return "長寿"
        }
    }
}

public struct FameEntry: Codable, Sendable, Identifiable {
    public var uid: UInt64
    public var speciesId: Int32
    public var speciesName: String
    public var generation: Int32
    public var value: Float
    public var hue: Float
    public var diet: Float
    /// nil while the creature is still alive.
    public var deathTick: Int64?
    public var id: UInt64 { uid }
}

extension World {
    func fameEntry(_ i: Int, _ kind: FameKind, dead: Bool) -> FameEntry {
        let v: Float
        switch kind {
        case .kills: v = Float(kills[i])
        case .offspring: v = Float(offspring[i])
        case .longevity: v = age[i]
        }
        return FameEntry(uid: uid[i], speciesId: speciesOf[i], speciesName: speciesName(i), generation: generation[i],
                         value: v, hue: genes[i].hue, diet: genes[i].diet, deathTick: dead ? tick : nil)
    }

    func recordFame(_ i: Int) {
        for kind in FameKind.allCases {
            let e = fameEntry(i, kind, dead: true)
            guard e.value > 0 else { continue }
            var list = hall[kind.rawValue]
            if list.count < 10 || e.value > (list.last?.value ?? 0) {
                list.append(e)
                list.sort { $0.value > $1.value }
                if list.count > 10 { list.removeLast(list.count - 10) }
                hall[kind.rawValue] = list
            }
        }
    }

    /// Top 10 for a category, including creatures still alive.
    public func hallOfFame(_ kind: FameKind) -> [FameEntry] {
        var list = hall[kind.rawValue]
        var living: [FameEntry] = []
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue {
            let e = fameEntry(i, kind, dead: false)
            if e.value > 0 { living.append(e) }
        }
        living.sort { $0.value > $1.value }
        list += living.prefix(10)
        list.sort { $0.value > $1.value }
        return Array(list.prefix(10))
    }
}

// MARK: - Time-lapse history

/// A compact picture of the world at one moment, for the time-lapse player.
public struct HistoryFrame: Sendable {
    public var tick: Int64
    /// 12 half-floats per creature: x, y, heading, radius, hue, saturation, diet,
    /// segments, fins, tail, pattern, eyes.
    public var creatures: [Float16]
    /// Interleaved x, y of a subsample of the plants.
    public var plants: [Float16]
    public var population: Int32
    public var carnivores: Int32
    public var maxGeneration: Int32

    public static let stride = 12
    public var creatureCount: Int { creatures.count / HistoryFrame.stride }

    /// Expands creature `k` into a render instance.
    public func instance(_ k: Int) -> CreatureInstance {
        let b = k * HistoryFrame.stride
        let c = creatures
        return CreatureInstance(
            position: V2(Float(c[b]), Float(c[b + 1])), velocity: .zero, heading: Float(c[b + 2]),
            radius: Float(c[b + 3]), hue: Float(c[b + 4]), saturation: Float(c[b + 5]), diet: Float(c[b + 6]),
            swimPhase: Float(k) * 0.7, segments: Float(c[b + 7]), fins: Float(c[b + 8]), tail: Float(c[b + 9]),
            pattern: Float(c[b + 10]), eyes: Float(c[b + 11]), energy: 0.7, hurt: 0, flags: 0, maturity: 1, signal: 0)
    }
}

extension World {
    func captureHistory() {
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
        let step = max(1, plantCount / 3000)
        var k = 0
        for f in 0..<foodCount where foodKind[f] == 0 && foodEnergy[f] > 0 {
            if k % step == 0 { p += [Float16(foodPos[f].x), Float16(foodPos[f].y)] }
            k += 1
        }
        history.append(HistoryFrame(tick: tick, creatures: c, plants: p, population: Int32(aliveCount),
                                    carnivores: carn, maxGeneration: maxGeneration))
        // Keep memory bounded: when full, drop every other old frame (coarser further back).
        if history.count > 320 {
            var thinned: [HistoryFrame] = []
            for (n, h) in history.enumerated() where n % 2 == 0 || n >= history.count - 80 { thinned.append(h) }
            history = thinned
        }
    }
}

// MARK: - Arena (duel between generations)

extension World {
    /// Builds a small arena in assay mode: no metabolism, ageing, reproduction or predation,
    /// constant plant density drawn from `seed` (identical for arenas with the same seed).
    public static func makeArena(_ genomes: [(Genes, BrainGenome)], base: SimConfig, seed: UInt64,
                                 size: Float = 2400, plants: Int = 600) -> World {
        var c = base
        c.worldWidth = size
        c.worldHeight = size
        c.maxCreatures = max(genomes.count + 8, 16)
        let w = World(config: c, seed: seed, populate: false)
        w.assayMode = true
        w.assayRng = RNG(seed: seed &+ 1)
        w.assayPlants = plants
        var rng = RNG(seed: seed &+ 2)
        let n = genomes.count
        let side = Int(Double(n).squareRoot().rounded(.up))
        for (k, (g, b)) in genomes.enumerated() {
            let cell = c.worldWidth / Float(side)
            let p = V2((Float(k % side) + 0.5) * cell, (Float(k / side) + 0.5) * cell)
            if let i = w.spawn(genes: g, brain: b, at: p, energy: 0, asEgg: false, species: -1, parent: -1, generation: 0) {
                w.age[i] = c.maturityAge
                w.rad[i] = w.radius(i)
                w.health[i] = w.maxHealth(i)
                w.energy[i] = w.capacityOf(i) * 0.5
                w.heading[i] = rng.float(-.pi, .pi)
            }
        }
        w.foodDynamics()
        return w
    }

    /// Plant energy gathered so far in arena mode.
    public var arenaGathered: Double { assayEaten }
}
