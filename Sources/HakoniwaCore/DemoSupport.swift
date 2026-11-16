import Foundation
import simd

/// Something worth pointing the demo camera at, found by `World.demoScan()`.
/// Every field is a plain value copied from the world, so captions can quote real data.
public struct DemoHighlight: Sendable {
    public enum Kind: Int, Sendable, CaseIterable {
        /// A carnivore (or omnivore) biting another creature right now.
        case hunt
        /// Many members of one species close together.
        case herd
        /// An egg a few seconds before hatching.
        case hatch
        /// One of the largest adult carnivores.
        case bigCarnivore
        /// A vividly coloured creature whose hue few others share.
        case rareColor
        /// A herbivore eating a plant.
        case forager
    }

    public var kind: Kind
    public var uid: UInt64
    public var position: V2
    public var speciesId: Int32
    public var speciesName: String
    /// Seconds of world time since the species branched off.
    public var speciesAge: Double
    public var parentSpeciesName: String?
    public var diet: Float
    public var generation: Int32
    public var kills: Int32
    public var offspring: Int32
    public var radius: Float
    public var hue: Float
    public var saturation: Float
    /// Herd: number of members nearby. Big carnivore: number of adult carnivores compared.
    public var groupCount: Int = 0
    /// Herd: RMS distance of the members from their centre (world units).
    public var groupRadius: Float = 0
    /// Herd: 0 = headings at random, 1 = everyone swims the same way.
    public var alignment: Float = 0
    /// Hunt: the creature being bitten.
    public var preySpeciesName: String?
    public var preyDiet: Float = 0
    /// Rare colour: share of the population with a similar hue (0...1).
    public var share: Float = 0
    /// Hatch: seconds until the egg hatches.
    public var secondsLeft: Float = 0
    /// Big carnivore: 1 = the largest adult carnivore in the world.
    public var rank: Int = 0
    /// Higher is more interesting within the same kind.
    public var score: Float = 0

    public static func dietLabel(_ d: Float) -> String { d < 0.35 ? "草食" : (d < 0.65 ? "雑食" : "肉食") }
    public var dietLabel: String { Self.dietLabel(diet) }
}

/// Result of one scan: the best candidates of each kind plus world-wide figures for captions.
public struct DemoScan: Sendable {
    public var tick: Int64 = 0
    public var worldTime: Double = 0
    public var population = 0
    public var eggs = 0
    public var herbivores = 0
    public var omnivores = 0
    public var carnivores = 0
    public var speciesAlive = 0
    public var maxGeneration: Int32 = 0
    public var totalBirths = 0
    /// Centre of the densest region (for wide shots).
    public var busiestPoint: V2 = .zero
    public var highlights: [DemoHighlight] = []

    public init() {}

    public func best(_ kind: DemoHighlight.Kind) -> [DemoHighlight] {
        highlights.filter { $0.kind == kind }.sorted { $0.score > $1.score }
    }
}

extension World {
    /// Looks for scenes worth showing: hunts, herds, hatching eggs, big carnivores, rare colours.
    /// Read-only and cheap (a few passes over the living creatures); call it on the simulation thread.
    public func demoScan(perKind: Int = 4) -> DemoScan {
        var scan = DemoScan()
        scan.tick = tick
        scan.worldTime = worldTime
        scan.population = aliveCount
        scan.eggs = eggCount
        scan.maxGeneration = maxGeneration
        scan.totalBirths = totalBirths
        for s in species where s.population > 0 { scan.speciesAlive += 1 }
        let ws = config.worldSize

        func make(_ kind: DemoHighlight.Kind, _ i: Int, score: Float) -> DemoHighlight {
            let sp = speciesOf[i]
            var name = "—", age = 0.0
            var parent: String?
            if sp >= 0 && Int(sp) < species.count {
                let r = species[Int(sp)]
                name = r.name
                age = Double(tick - r.birthTick) * Double(config.dt)
                if r.parentId >= 0 && Int(r.parentId) < species.count { parent = species[Int(r.parentId)].name }
            }
            let g = genes[i]
            return DemoHighlight(kind: kind, uid: uid[i], position: pos[i], speciesId: sp, speciesName: name,
                                 speciesAge: age, parentSpeciesName: parent, diet: g.diet, generation: generation[i],
                                 kills: kills[i], offspring: offspring[i], radius: rad[i], hue: g.hue,
                                 saturation: g.saturation, score: score)
        }

        var hunts: [DemoHighlight] = []
        var foragers: [DemoHighlight] = []
        var hatches: [DemoHighlight] = []
        var bigs: [(Int, Float)] = []
        var adultCarnivores = 0
        // Hue histogram of coloured adults, for rarity.
        let bins = 36
        var hueBins = [Int](repeating: 0, count: bins)
        var coloured = 0
        // Density grid for herds and the busiest point.
        let cell: Float = 180
        let ncx = max(Int(ws.x / cell), 1), ncy = max(Int(ws.y / cell), 1)
        var density = [Int](repeating: 0, count: ncx * ncy)
        var herdCells: [Int64: Int] = [:]

        for i in 0..<highWater where stage[i] != 0 {
            let p = pos[i]
            if stage[i] == Stage.egg.rawValue {
                let left = eggTimer[i]
                if left > 1.2 && left < 4.5 {
                    var h = make(.hatch, i, score: 4.5 - left)
                    h.secondsLeft = left
                    hatches.append(h)
                }
                continue
            }
            let g = genes[i]
            let cx = min(max(Int(p.x / cell), 0), ncx - 1), cy = min(max(Int(p.y / cell), 0), ncy - 1)
            density[cy * ncx + cx] += 1
            if g.diet < 0.35 { scan.herbivores += 1 } else if g.diet < 0.65 { scan.omnivores += 1 } else { scan.carnivores += 1 }
            let mature = maturity(i) >= 0.8
            if speciesOf[i] >= 0 {
                let key = (Int64(cy * ncx + cx) << 24) | Int64(speciesOf[i])
                herdCells[key, default: 0] += 1
            }
            if mature && g.saturation > 0.25 {
                hueBins[min(Int(g.hue * Float(bins)), bins - 1)] += 1
                coloured += 1
            }
            if g.diet >= 0.65 && mature {
                adultCarnivores += 1
                bigs.append((i, rad[i]))
            }
            let out = outputs + i * Brain.outputs
            let t = Int(biteTarget[i])
            if g.diet >= 0.5 && out[Brain.outBite] > 0 && t >= 0 && t != i && stage[t] == Stage.alive.rawValue
                && simd_length(torusDelta(pos[t] - p, ws)) < rad[i] + rad[t] + 5 {
                var h = make(.hunt, i, score: g.diet * 2 + Float(min(kills[i], 10)) * 0.2 + Float(min(generation[i], 400)) / 400)
                let ts = speciesOf[t]
                h.preySpeciesName = ts >= 0 && Int(ts) < species.count ? species[Int(ts)].name : nil
                h.preyDiet = genes[t].diet
                hunts.append(h)
            } else if g.diet < 0.35 && mature && out[Brain.outEat] > 0 && foodTarget[i] >= 0 {
                foragers.append(make(.forager, i, score: Float(min(generation[i], 400)) / 400 + Float(min(offspring[i], 20)) * 0.05))
            }
        }

        scan.highlights += hunts.sorted { $0.score > $1.score }.prefix(perKind)
        scan.highlights += hatches.sorted { $0.score > $1.score }.prefix(perKind)
        scan.highlights += foragers.sorted { $0.score > $1.score }.prefix(perKind)

        // Big carnivores: the largest adults, when carnivores are an established part of the world
        // (a lone fresh immigrant is not a story). The rank counts every adult carnivore.
        var emitted = 0
        for (rank, (i, r)) in bigs.sorted(by: { $0.1 > $1.1 }).enumerated() where adultCarnivores >= 5 {
            if emitted >= perKind || rank >= perKind * 3 { break }
            guard generation[i] >= 5 else { continue }
            emitted += 1
            var h = make(.bigCarnivore, i, score: r - Float(rank))
            h.groupCount = adultCarnivores
            h.rank = rank + 1
            h.score = Float(perKind - rank)
            scan.highlights.append(h)
        }

        // Rare colours: vivid adults in the emptiest part of the hue histogram.
        if coloured >= 30 {
            var rare: [DemoHighlight] = []
            for i in 0..<highWater where stage[i] == Stage.alive.rawValue {
                let g = genes[i]
                // Fresh immigrants are trivially rare; show colours that evolved.
                guard g.saturation > 0.55, maturity(i) >= 0.8, generation[i] >= 5 else { continue }
                let b = min(Int(g.hue * Float(bins)), bins - 1)
                let near = hueBins[(b + bins - 1) % bins] + hueBins[b] + hueBins[(b + 1) % bins]
                let share = Float(near) / Float(coloured)
                guard share < 0.05 else { continue }
                var h = make(.rareColor, i, score: (0.05 - share) * 100 + g.saturation)
                h.share = share
                rare.append(h)
            }
            // One per hue region.
            var used = Set<Int>()
            for h in rare.sorted(by: { $0.score > $1.score }) {
                let b = min(Int(h.hue * Float(bins)), bins - 1) / 3
                if used.insert(b).inserted { scan.highlights.append(h) }
                if used.count >= perKind { break }
            }
        }

        // Herds: the (cell, species) pairs with the most members, refined around their centroid.
        var herds: [DemoHighlight] = []
        let top = herdCells.filter { $0.value >= 6 }.sorted { $0.value > $1.value }.prefix(12)
        let reach: Float = 240
        for (key, _) in top {
            let sp = Int32(truncatingIfNeeded: key & 0xFFFFFF)
            let c = Int(key >> 24)
            let center = V2((Float(c % ncx) + 0.5) * cell, (Float(c / ncx) + 0.5) * cell)
            // Two passes: centroid of the nearby members, then statistics around it.
            var sum = V2.zero, n = 0
            for i in 0..<highWater where stage[i] == Stage.alive.rawValue && speciesOf[i] == sp {
                let d = torusDelta(pos[i] - center, ws)
                if simd_length(d) < reach { sum += d; n += 1 }
            }
            guard n >= 8 else { continue }
            let mid = torusWrap(center + sum / Float(n), ws)
            var members: [Int] = []
            var spread: Float = 0, heading = V2.zero, moving = 0, everyone = 0
            for i in 0..<highWater where stage[i] == Stage.alive.rawValue {
                let d = torusDelta(pos[i] - mid, ws)
                let l = simd_length(d)
                guard l < reach else { continue }
                everyone += 1
                guard speciesOf[i] == sp else { continue }
                members.append(i)
                spread += l * l
                let v = vel[i], s = simd_length(v)
                if s > 4 { heading += v / s; moving += 1 }
            }
            // A herd stands out only if its own kind dominates the spot.
            let purity = Float(members.count) / Float(max(everyone, 1))
            // ...and only if it is much denser than its species is on average.
            let pop = Float(species[Int(sp)].population)
            let expected = max(pop * .pi * reach * reach / (ws.x * ws.y), 1)
            let contrast = Float(members.count) / expected
            guard members.count >= 8, purity >= 0.5, contrast >= 2.5 else { continue }
            if herds.contains(where: { simd_length(torusDelta($0.position - mid, ws)) < reach * 1.5 }) { continue }
            // Anchor on the member closest to the centre so the camera can track a real creature.
            let anchor = members.min { simd_length_squared(torusDelta(pos[$0] - mid, ws)) < simd_length_squared(torusDelta(pos[$1] - mid, ws)) }!
            var h = make(.herd, anchor, score: Float(members.count) * purity * purity * contrast)
            h.position = mid
            h.groupCount = members.count
            h.groupRadius = (spread / Float(members.count)).squareRoot()
            h.alignment = moving >= 6 ? simd_length(heading) / Float(moving) : 0
            herds.append(h)
        }
        scan.highlights += herds.sorted { $0.score > $1.score }.prefix(perKind)

        if let k = density.indices.max(by: { density[$0] < density[$1] }) {
            scan.busiestPoint = V2((Float(k % ncx) + 0.5) * cell, (Float(k / ncx) + 0.5) * cell)
        }
        return scan
    }
}
