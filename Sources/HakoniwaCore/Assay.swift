import Foundation

/// Standardised foraging test. Creatures are placed in an identical arena with a constant,
/// uniform density of plants and no metabolism, ageing, reproduction or predation; we then
/// measure how much plant matter they gather. Comparing evolved creatures with primordial
/// (generation 0) ones shows whether foraging behaviour has actually evolved.
public struct AssayResult: Sendable, CustomStringConvertible {
    public var creatures: Int
    public var seconds: Float
    /// Plant energy gathered per creature per minute.
    public var energyPerMinute: Double
    /// Mean seconds needed to gather one plant pellet.
    public var secondsPerPellet: Double
    public var description: String {
        String(format: "%d creatures, %.0fs: %.1f energy/min, %.2f s per pellet", creatures, seconds, energyPerMinute, secondsPerPellet)
    }
}

extension World {
    /// Samples up to `count` living, adult-capable creatures (deterministically spread over slots).
    public func sampleGenomes(_ count: Int) -> [(Genes, BrainGenome)] {
        var all: [Int] = []
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue { all.append(i) }
        guard !all.isEmpty else { return [] }
        let step = max(1, all.count / count)
        return stride(from: 0, to: all.count, by: step).prefix(count).map { (genes[all[$0]], brainGenome(all[$0])) }
    }

    /// Primordial genomes generated exactly as a new world would.
    public static func primordialGenomes(_ count: Int, seed: UInt64, config: SimConfig) -> [(Genes, BrainGenome)] {
        var c = config
        c.initialCreatures = max(count, 14)
        let w = World(config: c, seed: seed)
        return w.sampleGenomes(count)
    }

    public static func assay(_ genomes: [(Genes, BrainGenome)], base: SimConfig, seed: UInt64 = 77,
                             seconds: Float = 120) -> AssayResult {
        var c = base
        c.worldWidth = 2400
        c.worldHeight = 2400
        c.maxCreatures = max(genomes.count + 8, 16)
        let w = World(config: c, seed: seed, populate: false)
        w.assayMode = true
        w.assayRng = RNG(seed: seed &+ 1)
        // Sparse enough that searching matters (~1 pellet per 9,600 square units).
        w.assayPlants = 600
        var rng = RNG(seed: seed &+ 2)
        // Each creature starts in its own region so they barely interact.
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
        let ticks = Int(seconds * c.ticksPerSecond)
        w.step(ticks)
        let perCreatureMinute = w.assayEaten / Double(max(n, 1)) / Double(seconds / 60)
        return AssayResult(creatures: n, seconds: seconds, energyPerMinute: perCreatureMinute,
                           secondsPerPellet: perCreatureMinute > 0 ? 60 * Double(c.plantEnergy) / perCreatureMinute : .infinity)
    }
}
