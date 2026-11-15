import Foundation
import simd

/// Per-creature data uploaded to the GPU. Layout must match `CreatureInstance` in the Metal shader
/// (20 floats, 80 bytes).
public struct CreatureInstance: Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var heading: Float
    public var radius: Float
    public var hue: Float
    public var saturation: Float
    public var diet: Float
    public var swimPhase: Float
    public var segments: Float
    public var fins: Float
    public var tail: Float
    public var pattern: Float
    public var eyes: Float
    /// Energy relative to capacity, 0...1.
    public var energy: Float
    /// 1 right after being bitten, decays to 0.
    public var hurt: Float
    /// Bit flags: 1 = egg, 2 = biting, 4 = eating, 8 = selected (set by the renderer).
    public var flags: Float
    /// Growth 0...1 for creatures; hatch progress 0...1 for eggs.
    public var maturity: Float
    public var signal: Float
}

/// Per-food data uploaded to the GPU (4 floats).
public struct FoodInstance: Sendable {
    public var position: SIMD2<Float>
    public var energy: Float
    /// 0 = plant, 1 = meat.
    public var kind: Float
}

/// Everything the renderer needs for one frame. Reused between frames to avoid allocation.
public final class RenderSnapshot: @unchecked Sendable {
    public var creatures: [CreatureInstance] = []
    public var uids: [UInt64] = []
    public var food: [FoodInstance] = []
    public var fx: [FXEvent] = []
    public var tick: Int64 = 0
    public var worldSize: V2 = .zero
    public var ticksPerSecond: Float = 20
    public var season: Float = 1
    /// Fertility map (`FertilityField.resolution`² values), refreshed occasionally.
    public var fertility: [Float] = []
    public var fertilityTick: Int64 = -1

    public init() {}
}

/// Complete state of one creature for the inspector panel.
public struct CreatureDetail: Sendable {
    public var uid: UInt64
    public var parentUid: UInt64
    public var isEgg: Bool
    public var speciesId: Int32
    public var speciesName: String
    public var generation: Int32
    public var age: Float
    public var lifespan: Float
    /// Growth 0...1 for creatures; hatch progress 0...1 for eggs.
    public var maturity: Float
    public var energy: Float
    public var capacity: Float
    public var health: Float
    public var maxHealth: Float
    public var radius: Float
    public var position: V2
    public var velocity: V2
    public var heading: Float
    public var genes: Genes
    public var phenotype: Phenotype
    public var kills: Int32
    public var offspring: Int32
    public var eaten: Float
    public var brain: BrainGenome
    public var inputs: [Float]
    public var hidden: [Float]
    public var outputs: [Float]
}

extension World {
    /// Fills `snap` with the current state. Cheap enough to call every frame.
    public func fillRender(_ snap: RenderSnapshot) {
        snap.tick = tick
        snap.worldSize = config.worldSize
        snap.ticksPerSecond = config.ticksPerSecond
        snap.season = seasonFactor
        snap.creatures.removeAll(keepingCapacity: true)
        snap.uids.removeAll(keepingCapacity: true)
        snap.creatures.reserveCapacity(aliveCount + eggCount)
        for i in 0..<highWater where stage[i] != 0 {
            let g = genes[i]
            let isEgg = stage[i] == Stage.egg.rawValue
            let out = outputs + i * Brain.outputs
            var flags: Float = 0
            if isEgg { flags += 1 }
            if !isEgg && out[Brain.outBite] > 0 && biteTarget[i] >= 0 { flags += 2 }
            if !isEgg && out[Brain.outEat] > 0 && foodTarget[i] >= 0 { flags += 4 }
            snap.creatures.append(CreatureInstance(
                position: pos[i], velocity: isEgg ? .zero : vel[i], heading: heading[i], radius: rad[i],
                hue: g.hue, saturation: g.saturation, diet: g.diet, swimPhase: swimPhase[i],
                segments: g.segments, fins: g.fins, tail: g.tail, pattern: g.pattern, eyes: g.eyes,
                energy: min(energy[i] / max(capacityOf(i), 1), 1), hurt: hurt[i], flags: flags,
                maturity: isEgg ? clamp01(1 - eggTimer[i] / config.eggHatchTime) : maturity(i), signal: max(signal1[i], signal2[i])))
            snap.uids.append(uid[i])
        }
        snap.food.removeAll(keepingCapacity: true)
        snap.food.reserveCapacity(foodCount)
        for k in 0..<foodCount where foodEnergy[k] > 0 {
            snap.food.append(FoodInstance(position: foodPos[k], energy: foodEnergy[k], kind: Float(foodKind[k])))
        }
        snap.fx.append(contentsOf: fxEvents)
        fxEvents.removeAll(keepingCapacity: true)
        if snap.fertilityTick < 0 || tick - snap.fertilityTick > Int64(config.ticksPerSecond * 5) {
            snap.fertility = fertility.snapshot(time: Float(tick) * config.dt, driftPeriod: config.fertilityDriftPeriod)
            snap.fertilityTick = tick
        }
    }

    public func slot(of uid: UInt64) -> Int? {
        guard uid != 0 else { return nil }
        for i in 0..<highWater where self.uid[i] == uid && stage[i] != 0 { return i }
        return nil
    }

    /// The creature nearest to `point` within `maxDistance` (world units), if any.
    public func creature(near point: V2, maxDistance: Float) -> UInt64? {
        var best: Float = maxDistance
        var found: UInt64?
        for i in 0..<highWater where stage[i] != 0 {
            let d = simd_length(torusDelta(pos[i] - point, config.worldSize)) - rad[i]
            if d < best { best = d; found = uid[i] }
        }
        return found
    }

    public func detail(uid: UInt64) -> CreatureDetail? {
        guard let i = slot(of: uid) else { return nil }
        let sp = speciesOf[i]
        let name = sp >= 0 && Int(sp) < species.count ? species[Int(sp)].name : "—"
        return CreatureDetail(
            uid: uid, parentUid: parentUid[i], isEgg: stage[i] == Stage.egg.rawValue,
            speciesId: sp, speciesName: name, generation: generation[i],
            age: age[i], lifespan: pheno[i].lifespan, maturity: maturity(i),
            energy: energy[i], capacity: capacityOf(i), health: health[i], maxHealth: maxHealth(i),
            radius: rad[i], position: pos[i], velocity: vel[i], heading: heading[i],
            genes: genes[i], phenotype: pheno[i], kills: kills[i], offspring: offspring[i], eaten: eaten[i],
            brain: brainGenome(i),
            inputs: Array(UnsafeBufferPointer(start: inputs + i * Brain.inputs, count: Brain.inputs)),
            hidden: Array(UnsafeBufferPointer(start: hiddenState + i * Brain.hidden, count: Brain.hidden)),
            outputs: Array(UnsafeBufferPointer(start: outputs + i * Brain.outputs, count: Brain.outputs)))
    }

    /// Chain of species from the given one back to its primordial ancestor.
    public func lineage(of speciesId: Int32) -> [SpeciesRecord] {
        var out: [SpeciesRecord] = []
        var s = speciesId
        while s >= 0 && Int(s) < species.count {
            out.append(species[Int(s)])
            s = species[Int(s)].parentId
        }
        return out
    }

    public var livingSpecies: [SpeciesRecord] { species.filter { $0.population > 0 } }

    // MARK: - Interventions (energy always comes from or returns to the soil)

    /// Scatters plants around a point, paid for from the soil.
    public func dropFood(at p: V2, radius: Float, count: Int) {
        var placed = 0
        for _ in 0..<count {
            guard soil >= config.plantEnergy, foodCount < foodCapacity, plantCount < config.maxPlants else { break }
            let a = rng.float(0, 2 * .pi), r = radius * rng.float().squareRoot()
            foodPos[foodCount] = torusWrap(p + V2(cos(a), sin(a)) * r, config.worldSize)
            foodEnergy[foodCount] = config.plantEnergy
            foodKind[foodCount] = 0
            foodCount += 1
            plantCount += 1
            soil -= config.plantEnergy
            placed += 1
        }
        if placed > 0 { log(.intervention, "餌を\(placed)個まいた") }
    }

    /// Places a mutated copy of an existing creature (or a fresh random one) at a point.
    @discardableResult
    public func spawnCreature(at p: V2, copying source: UInt64?) -> UInt64? {
        var g: Genes, b: BrainGenome, sp: Int32, gen: Int32 = 0, parent = -1
        if let s = source, let i = slot(of: s) {
            g = genes[i]; g.mutate(&rng)
            b = brainGenome(i); BrainOps.mutate(&b, rate: g.mutationRate, &rng)
            sp = speciesOf[i]; gen = generation[i] + 1; parent = i
        } else {
            g = Genes.random(&rng)
            b = BrainOps.randomGenome(&rng, connections: config.initialConnections)
            sp = newSpecies(parent: -1, genes: g, brain: b)
        }
        let e = Phenotype(g, config).capacityAdult * 0.4
        guard soil > e, let i = spawn(genes: g, brain: b, at: p, energy: e, asEgg: false, species: sp,
                                      parent: parent, generation: gen) else { return nil }
        soil -= e
        age[i] = config.maturityAge
        rad[i] = radius(i)
        health[i] = maxHealth(i)
        if collectFX { fx(.birth, i) }
        return uid[i]
    }

    public func remove(uid u: UInt64) {
        guard let i = slot(of: u) else { return }
        die(i, cause: .removed)
    }

    /// Kills every creature within `radius` of `p` and scorches the plants there.
    public func meteor(at p: V2, radius: Float) {
        var killed = 0
        for i in 0..<highWater where stage[i] != 0 {
            if simd_length(torusDelta(pos[i] - p, config.worldSize)) < radius {
                die(i, cause: .removed)
                killed += 1
            }
        }
        for k in 0..<foodCount where foodEnergy[k] > 0 && foodKind[k] == 0 {
            if simd_length(torusDelta(foodPos[k] - p, config.worldSize)) < radius {
                soil += foodEnergy[k]
                foodEnergy[k] = 0
                plantCount -= 1
                foodRemoved = true
            }
        }
        if foodRemoved { compactFood() }
        if collectFX && fxEvents.count < 4096 {
            fxEvents.append(FXEvent(kind: .meteor, position: p, hue: 0.05, size: radius))
        }
        log(.intervention, "隕石が落ちた(\(killed)匹が犠牲に)")
    }
}
