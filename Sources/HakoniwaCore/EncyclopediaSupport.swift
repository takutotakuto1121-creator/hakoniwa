import Foundation
import simd

// Read-only queries for the species encyclopedia and for named ("pet") creatures.
// Nothing here changes the world, so determinism and energy conservation are untouched.

/// Mean traits of the living members of one species.
public struct SpeciesMembers: Sendable {
    public var speciesId: Int32
    /// Hatched creatures only (eggs are not counted).
    public var count: Int
    /// Mean genes; the hue is a circular mean.
    public var meanGenes: Genes
    public var meanGeneration: Float
}

/// Where a tracked creature is and how it is doing.
public struct CreatureStatus: Sendable {
    public var uid: UInt64
    public var speciesId: Int32
    public var generation: Int32
    public var isEgg: Bool
    public var age: Float
    public var offspring: Int32
    public var kills: Int32
    public var position: V2
    public var genes: Genes
}

extension World {
    /// Mean genes of the hatched members of every species that has any.
    public func speciesMembers() -> [Int32: SpeciesMembers] {
        var sums: [Int32: (n: Int, g: SIMD16<Float>, hx: Float, hy: Float, gen: Float)] = [:]
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue {
            let sp = speciesOf[i]
            guard sp >= 0 else { continue }
            let g = genes[i]
            let a = g.hue * 2 * .pi
            var s = sums[sp] ?? (0, SIMD16<Float>(repeating: 0), 0, 0, 0)
            s.n += 1
            s.g += g.v
            s.hx += cos(a); s.hy += sin(a)
            s.gen += Float(generation[i])
            sums[sp] = s
        }
        var out: [Int32: SpeciesMembers] = [:]
        for (sp, s) in sums {
            let n = Float(s.n)
            var g = Genes(s.g / n)
            var h = atan2(s.hy, s.hx) / (2 * .pi)
            if h < 0 { h += 1 }
            g.hue = h
            out[sp] = SpeciesMembers(speciesId: sp, count: s.n, meanGenes: g, meanGeneration: s.gen / n)
        }
        return out
    }

    /// uids of the living (hatched) members of a species, most evolved first.
    public func members(ofSpecies sp: Int32, limit: Int = 64) -> [UInt64] {
        var found: [(UInt64, Int32)] = []
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue && speciesOf[i] == sp {
            found.append((uid[i], generation[i]))
        }
        found.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return found.prefix(limit).map(\.0)
    }

    /// Current status of each of the given creatures that still exists (eggs included).
    public func status(of uids: Set<UInt64>) -> [UInt64: CreatureStatus] {
        guard !uids.isEmpty else { return [:] }
        var out: [UInt64: CreatureStatus] = [:]
        for i in 0..<highWater where stage[i] != Stage.free.rawValue && uids.contains(uid[i]) {
            out[uid[i]] = CreatureStatus(
                uid: uid[i], speciesId: speciesOf[i], generation: generation[i],
                isEgg: stage[i] == Stage.egg.rawValue, age: age[i], offspring: offspring[i], kills: kills[i],
                position: pos[i], genes: genes[i])
        }
        return out
    }
}

extension CreatureDetail {
    /// A healthy adult with the given genes, for drawing portraits of species (not a real creature).
    public static func portraitStandIn(genes g: Genes, seed: UInt64, config: SimConfig = SimConfig()) -> CreatureDetail {
        let ph = Phenotype(g, config)
        return CreatureDetail(
            uid: seed, parentUid: 0, isEgg: false, speciesId: -1, speciesName: "", generation: 0,
            age: config.maturityAge, lifespan: ph.lifespan, maturity: 1,
            energy: ph.capacityAdult, capacity: ph.capacityAdult, health: 1, maxHealth: 1,
            radius: ph.radiusAdult, position: .zero, velocity: .zero, heading: 0,
            genes: g, phenotype: ph, kills: 0, offspring: 0, eaten: 0,
            brain: BrainGenome(connections: [], biases: []), inputs: [], hidden: [], outputs: [])
    }
}
