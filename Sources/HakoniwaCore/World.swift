import Foundation
import simd

/// Life stage stored per slot.
public enum Stage: UInt8, Sendable {
    case free = 0, egg = 1, alive = 2
}

public enum DeathCause: Sendable { case starved, killed, old, removed }

/// Visual effect events emitted for the renderer.
public struct FXEvent: Sendable {
    public enum Kind: UInt8, Sendable { case birth, death, kill, hatch, meteor, feed }
    public var kind: Kind
    public var position: V2
    public var hue: Float
    public var size: Float
}

/// The simulated world. Not thread-safe: one thread owns a World at a time.
///
/// Each tick runs these phases:
///  1. build spatial grids (sequential, O(n))
///  2. sense + think (parallel; each creature writes only its own slot)
///  3. act: movement and metabolism (parallel; own slot only)
///  4. interactions: eating, biting, laying eggs (sequential, slot order)
///  5. deaths, hatching, food dynamics, repopulation (sequential)
/// Because parallel phases only write per-slot data and sequential phases run in a
/// fixed order, results are independent of the number of threads.
public final class World {
    public let config: SimConfig
    public let seed: UInt64
    public internal(set) var tick: Int64 = 0
    var rng: RNG
    public var parallel = true

    // MARK: Creature pool (structure of arrays)
    public let capacity: Int
    let stage: UnsafeMutablePointer<UInt8>
    let uid: UnsafeMutablePointer<UInt64>
    let parentUid: UnsafeMutablePointer<UInt64>
    let speciesOf: UnsafeMutablePointer<Int32>
    let generation: UnsafeMutablePointer<Int32>
    let birthTick: UnsafeMutablePointer<Int64>
    let pos: UnsafeMutablePointer<V2>
    let vel: UnsafeMutablePointer<V2>
    let push: UnsafeMutablePointer<V2>
    let heading: UnsafeMutablePointer<Float>
    let energy: UnsafeMutablePointer<Float>
    let health: UnsafeMutablePointer<Float>
    let age: UnsafeMutablePointer<Float>
    let hurt: UnsafeMutablePointer<Float>
    let signal1: UnsafeMutablePointer<Float>
    let signal2: UnsafeMutablePointer<Float>
    let swimPhase: UnsafeMutablePointer<Float>
    let lost: UnsafeMutablePointer<Float>
    /// Current body radius, refreshed every tick in the act phase.
    let rad: UnsafeMutablePointer<Float>
    /// Energy invested in body tissue while growing; becomes meat on death.
    let body: UnsafeMutablePointer<Float>
    let eggTimer: UnsafeMutablePointer<Float>
    let lastMeal: UnsafeMutablePointer<Float>
    let biteTarget: UnsafeMutablePointer<Int32>
    let foodTarget: UnsafeMutablePointer<Int32>
    let kills: UnsafeMutablePointer<Int32>
    let offspring: UnsafeMutablePointer<Int32>
    let eaten: UnsafeMutablePointer<Float>
    let genes: UnsafeMutablePointer<Genes>
    let pheno: UnsafeMutablePointer<Phenotype>
    let conns: UnsafeMutablePointer<Connection>
    let connCount: UnsafeMutablePointer<Int32>
    let connSplit: UnsafeMutablePointer<Int32>
    let biases: UnsafeMutablePointer<Float>
    let hiddenState: UnsafeMutablePointer<Float>
    let inputs: UnsafeMutablePointer<Float>
    let outputs: UnsafeMutablePointer<Float>
    var freeList: [Int32] = []
    public internal(set) var highWater = 0
    public internal(set) var aliveCount = 0
    public internal(set) var eggCount = 0
    var nextUid: UInt64 = 1

    // MARK: Food
    public let foodCapacity: Int
    let foodPos: UnsafeMutablePointer<V2>
    let foodEnergy: UnsafeMutablePointer<Float>
    let foodKind: UnsafeMutablePointer<UInt8>   // 0 plant, 1 meat
    public internal(set) var foodCount = 0
    public internal(set) var plantCount = 0
    public internal(set) var meatCount = 0
    var foodRemoved = false

    // MARK: Environment
    public internal(set) var soil: Float = 0
    var plantAccumulator: Float = 0
    let fertility: FertilityField

    // MARK: Grids
    let creatureGrid: SpatialGrid
    let foodGrid: SpatialGrid

    // MARK: Evolution bookkeeping
    public internal(set) var species: [SpeciesRecord] = []
    public internal(set) var maxGeneration: Int32 = 0
    public internal(set) var events: [WorldEvent] = []
    var nextEventId = 0
    var firstCarnivoreReported = false
    var nextGenerationMilestone: Int32 = 10
    public internal(set) var samples: [StatSample] = []
    public var sampleInterval: Int64 = 200
    var window = StatWindow()
    public var fxEvents: [FXEvent] = []
    public var collectFX = false
    public internal(set) var totalBirths = 0

    let dragFactor: Float
    /// Assay mode: no metabolism, ageing, reproduction or predation; constant plant density.
    var assayMode = false
    var assayPlants = 0
    var assayEaten: Double = 0
    var assayRng = RNG(seed: 0)

    /// Creatures sense and think every `thinkInterval` ticks (staggered by slot).
    public var thinkInterval = 2

    public init(config: SimConfig = SimConfig(), seed: UInt64 = 1, populate: Bool = true) {
        self.config = config
        self.seed = seed
        self.rng = RNG(seed: seed)
        capacity = config.maxCreatures
        let n = capacity
        func a<T>(_ count: Int, _ v: T) -> UnsafeMutablePointer<T> {
            let p = UnsafeMutablePointer<T>.allocate(capacity: count)
            p.initialize(repeating: v, count: count)
            return p
        }
        stage = a(n, 0); uid = a(n, 0); parentUid = a(n, 0); speciesOf = a(n, -1)
        generation = a(n, 0); birthTick = a(n, 0)
        pos = a(n, .zero); vel = a(n, .zero); push = a(n, .zero)
        heading = a(n, 0); energy = a(n, 0); health = a(n, 0); age = a(n, 0); hurt = a(n, 0)
        signal1 = a(n, 0); signal2 = a(n, 0); swimPhase = a(n, 0); lost = a(n, 0); rad = a(n, 1); body = a(n, 0); eggTimer = a(n, 0)
        lastMeal = a(n, 0); biteTarget = a(n, -1); foodTarget = a(n, -1); kills = a(n, 0); offspring = a(n, 0)
        eaten = a(n, 0)
        genes = a(n, Genes(.zero))
        var dummyRng = RNG(seed: 0)
        pheno = a(n, Phenotype(Genes.random(&dummyRng), config))
        conns = a(n * Brain.maxConnections, Connection(src: 0, dst: 0, weight: 0))
        connCount = a(n, 0); connSplit = a(n, 0)
        biases = a(n * Brain.biasCount, 0)
        hiddenState = a(n * Brain.hidden, 0)
        inputs = a(n * Brain.inputs, 0)
        outputs = a(n * Brain.outputs, 0)
        freeList = (0..<Int32(n)).reversed().map { $0 }

        foodCapacity = config.maxPlants + config.maxMeat + 64
        foodPos = a(foodCapacity, .zero); foodEnergy = a(foodCapacity, 0); foodKind = a(foodCapacity, 0)

        fertility = FertilityField(seed: seed, worldSize: config.worldSize, contrast: config.fertilityContrast)
        creatureGrid = SpatialGrid(worldSize: config.worldSize, cellSize: 64, capacity: n)
        foodGrid = SpatialGrid(worldSize: config.worldSize, cellSize: 48, capacity: foodCapacity)
        dragFactor = exp(-config.drag * config.dt)

        soil = config.totalEnergy
        if populate { populateInitial() }
    }

    deinit {
        stage.deallocate(); uid.deallocate(); parentUid.deallocate(); speciesOf.deallocate()
        generation.deallocate(); birthTick.deallocate()
        pos.deallocate(); vel.deallocate(); push.deallocate()
        heading.deallocate(); energy.deallocate(); health.deallocate(); age.deallocate(); hurt.deallocate()
        signal1.deallocate(); signal2.deallocate(); swimPhase.deallocate(); lost.deallocate(); rad.deallocate(); body.deallocate(); eggTimer.deallocate()
        lastMeal.deallocate(); biteTarget.deallocate(); foodTarget.deallocate(); kills.deallocate()
        offspring.deallocate(); eaten.deallocate()
        genes.deallocate(); pheno.deallocate(); conns.deallocate(); connCount.deallocate(); connSplit.deallocate()
        biases.deallocate(); hiddenState.deallocate(); inputs.deallocate(); outputs.deallocate()
        foodPos.deallocate(); foodEnergy.deallocate(); foodKind.deallocate()
    }

    // MARK: - Derived quantities

    @inline(__always) func radius(_ i: Int) -> Float {
        pheno[i].radiusAdult * Phenotype.growth(stage[i] == Stage.egg.rawValue ? 0 : min(age[i] / config.maturityAge, 1))
    }

    @inline(__always) func maturity(_ i: Int) -> Float { min(age[i] / config.maturityAge, 1) }

    @inline(__always) func capacityOf(_ i: Int) -> Float {
        let g = Phenotype.growth(maturity(i))
        return pheno[i].capacityAdult * g * g
    }

    @inline(__always) func maxHealth(_ i: Int) -> Float {
        let r = radius(i)
        return config.healthPerMass * r * r
    }

    public var seasonFactor: Float {
        let t = Float(tick) * config.dt
        return 1 + config.seasonAmplitude * sin(2 * .pi * t / config.seasonPeriod)
    }

    public var worldTime: Double { Double(tick) / Double(config.ticksPerSecond) }

    // MARK: - Population management

    func allocateSlot() -> Int? {
        guard let s = freeList.popLast() else { return nil }
        let i = Int(s)
        if i >= highWater { highWater = i + 1 }
        return i
    }

    func freeSlot(_ i: Int) {
        stage[i] = Stage.free.rawValue
        uid[i] = 0
        freeList.append(Int32(i))
        // Shrink the high-water mark when the top slots are free.
        while highWater > 0 && stage[highWater - 1] == Stage.free.rawValue { highWater -= 1 }
    }

    func writeBrain(_ i: Int, _ b: BrainGenome) {
        let base = conns + i * Brain.maxConnections
        let n = min(b.connections.count, Brain.maxConnections)
        var split = n
        for k in 0..<n {
            base[k] = b.connections[k]
            if split == n && Int(b.connections[k].dst) >= Brain.hidden { split = k }
        }
        connCount[i] = Int32(n)
        connSplit[i] = Int32(split)
        let bb = biases + i * Brain.biasCount
        for k in 0..<Brain.biasCount { bb[k] = k < b.biases.count ? b.biases[k] : 0 }
        (hiddenState + i * Brain.hidden).update(repeating: 0, count: Brain.hidden)
        (outputs + i * Brain.outputs).update(repeating: 0, count: Brain.outputs)
        (inputs + i * Brain.inputs).update(repeating: 0, count: Brain.inputs)
    }

    public func brainGenome(_ i: Int) -> BrainGenome {
        let base = conns + i * Brain.maxConnections
        let c = Array(UnsafeBufferPointer(start: base, count: Int(connCount[i])))
        let b = Array(UnsafeBufferPointer(start: biases + i * Brain.biasCount, count: Brain.biasCount))
        return BrainGenome(connections: c, biases: b)
    }

    /// Places a new creature in the world. Energy is taken from `energySource`.
    @discardableResult
    func spawn(genes g: Genes, brain: BrainGenome, at p: V2, energy e: Float, asEgg: Bool,
               species sp: Int32, parent: Int, generation gen: Int32) -> Int? {
        guard let i = allocateSlot() else { return nil }
        stage[i] = asEgg ? Stage.egg.rawValue : Stage.alive.rawValue
        uid[i] = nextUid; nextUid += 1
        parentUid[i] = parent >= 0 ? uid[parent] : 0
        speciesOf[i] = sp
        generation[i] = gen
        birthTick[i] = tick
        pos[i] = torusWrap(p, config.worldSize)
        vel[i] = .zero
        push[i] = .zero
        heading[i] = rng.float(-.pi, .pi)
        energy[i] = e
        body[i] = 0
        genes[i] = g
        pheno[i] = Phenotype(g, config)
        age[i] = 0
        hurt[i] = 0
        signal1[i] = 0; signal2[i] = 0
        swimPhase[i] = rng.float(0, 6.28)
        lost[i] = 0
        eggTimer[i] = asEgg ? config.eggHatchTime * rng.float(0.8, 1.2) : 0
        lastMeal[i] = 0
        biteTarget[i] = -1; foodTarget[i] = -1
        kills[i] = 0; offspring[i] = 0; eaten[i] = 0
        writeBrain(i, brain)
        rad[i] = radius(i)
        health[i] = maxHealth(i)
        if asEgg { eggCount += 1 } else { aliveCount += 1 }
        if gen > maxGeneration { maxGeneration = gen }
        if sp >= 0 && Int(sp) < species.count {
            let rec = species[Int(sp)]
            rec.population += 1
            rec.totalBorn += 1
            if rec.population > rec.peakPopulation { rec.peakPopulation = rec.population }
            if gen > rec.maxGeneration { rec.maxGeneration = gen }
            if !rec.established && rec.population >= 8 { establish(rec) }
        }
        return i
    }

    func newSpecies(parent: Int32, genes g: Genes, brain: BrainGenome) -> Int32 {
        let id = Int32(species.count)
        var nameRng = RNG(seed: RNG.hash(seed, UInt64(id) &+ 77))
        let rec = SpeciesRecord(id: id, parentId: parent, name: SpeciesNamer.name(&nameRng),
                                genes: g, brain: brain, tick: tick)
        species.append(rec)
        return id
    }

    func establish(_ rec: SpeciesRecord) {
        rec.established = true
        rec.establishedTick = tick
        if rec.parentId >= 0 {
            let parent = species[Int(rec.parentId)]
            log(.speciation, "新種「\(rec.name)」が「\(parent.name)」から分岐", rec.id)
        }
    }

    func log(_ kind: EventKind, _ message: String, _ sp: Int32? = nil) {
        events.append(WorldEvent(id: nextEventId, tick: tick, kind: kind, message: message, speciesId: sp))
        nextEventId += 1
        if events.count > 4000 { events.removeFirst(events.count - 3000) }
    }

    func populateInitial() {
        // A handful of ancestral lineages, each with mutated variants.
        let lineages = 14
        let perLineage = max(1, config.initialCreatures / lineages)
        var ancestors: [(Genes, BrainGenome, Int32)] = []
        for l in 0..<lineages {
            var g = Genes.random(&rng)
            // A few lineages start with omnivorous or carnivorous digestion. This only widens
            // the initial genetic diversity; no behaviour is given to them.
            if l >= lineages - config.initialMeatEaterLineages { g.diet = rng.float(0.45, 0.95) }
            let b = BrainOps.randomGenome(&rng, connections: config.initialConnections)
            let sp = newSpecies(parent: -1, genes: g, brain: b)
            ancestors.append((g, b, sp))
        }
        for l in 0..<lineages {
            let (g0, b0, sp) = ancestors[l]
            let center = V2(rng.float(0, config.worldWidth), rng.float(0, config.worldHeight))
            for _ in 0..<perLineage {
                var g = g0; g.mutate(&rng)
                var b = b0; BrainOps.mutate(&b, rate: 0.6, &rng)
                let p = center + V2(rng.gaussian(), rng.gaussian()) * 500
                let e = Phenotype(g, config).capacityAdult * 0.5
                guard soil > e * 2 else { break }
                if let i = spawn(genes: g, brain: b, at: p, energy: e, asEgg: false, species: sp, parent: -1, generation: 0) {
                    soil -= e
                    age[i] = rng.float(0, config.maturityAge * 1.2)
                    rad[i] = radius(i)
                    health[i] = maxHealth(i)
                    // Primordial creatures start fully grown in tissue, paid for by the soil.
                    body[i] = config.bodyPerMass * rad[i] * rad[i]
                    soil -= body[i]
                }
            }
            species[Int(sp)].established = true
            species[Int(sp)].establishedTick = 0
        }
        // Initial plant cover: half of the remaining energy.
        let plantBudget = min(soil * 0.5, Float(config.maxPlants) * config.plantEnergy * 0.8)
        var spent: Float = 0
        while spent + config.plantEnergy <= plantBudget {
            addPlant()
            spent += config.plantEnergy
        }
        log(.milestone, "世界が生まれた(シード \(seed))")
    }

    @discardableResult
    func addPlant() -> Bool {
        guard foodCount < foodCapacity, plantCount < config.maxPlants, soil >= config.plantEnergy else { return false }
        let t = Float(tick) * config.dt
        var p = V2.zero
        for _ in 0..<10 {
            p = V2(rng.float(0, config.worldWidth), rng.float(0, config.worldHeight))
            if rng.float() < fertility.value(at: p, time: t, driftPeriod: config.fertilityDriftPeriod) { break }
        }
        let k = foodCount
        foodPos[k] = p
        foodEnergy[k] = config.plantEnergy
        foodKind[k] = 0
        foodCount += 1
        plantCount += 1
        soil -= config.plantEnergy
        return true
    }

    func addMeat(_ amount: Float, at p: V2, spread: Float) {
        var remaining = amount
        while remaining > 0.5 {
            let chunk = min(remaining, config.meatChunk)
            if foodCount < foodCapacity && meatCount < config.maxMeat {
                let k = foodCount
                let o = V2(rng.gaussian(), rng.gaussian()) * spread
                foodPos[k] = torusWrap(p + o, config.worldSize)
                foodEnergy[k] = chunk
                foodKind[k] = 1
                foodCount += 1
                meatCount += 1
            } else {
                soil += chunk
            }
            remaining -= chunk
        }
        soil += max(remaining, 0)
    }

    // MARK: - Stepping

    public func step(_ n: Int = 1) {
        for _ in 0..<n { stepOnce() }
    }

    /// When true, accumulated nanoseconds per phase are recorded in `phaseNanos`.
    public var profile = false
    public var phaseNanos = [UInt64](repeating: 0, count: 7)
    public static let phaseNames = ["grids", "sense", "act", "interact", "lifecycle", "food", "repopulate"]

    @inline(__always) func timed(_ k: Int, _ f: () -> Void) {
        if !profile { f(); return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        f()
        phaseNanos[k] += DispatchTime.now().uptimeNanoseconds - t0
    }

    func stepOnce() {
        timed(0) { buildGrids() }
        timed(1) { runParallel(sense) }
        timed(2) { runParallel(act) }
        timed(3) { interact() }
        timed(4) { lifecycle() }
        timed(5) { foodDynamics() }
        timed(6) { repopulate() }
        window.creatureTicks += Double(aliveCount)
        tick += 1
        if tick % sampleInterval == 0 { sample() }
        if tick % 900 == 0 { rebalanceEnergy() }
    }

    func buildGrids() {
        let st = stage, ps = pos, rd = rad, gn = genes
        creatureGrid.build(count: highWater, positions: pos, include: { st[$0] != 0 },
                           pack: { SIMD4(ps[$0].x, ps[$0].y, rd[$0], gn[$0].hue) })
        let fe = foodEnergy, fp = foodPos, fk = foodKind
        foodGrid.build(count: foodCount, positions: foodPos, include: { fe[$0] > 0 },
                       pack: { SIMD4(fp[$0].x, fp[$0].y, Float(fk[$0]), 0) })
    }

    func runParallel(_ body: (Int, Int) -> Void) {
        let n = highWater
        let chunk = 32
        let chunks = (n + chunk - 1) / chunk
        if !parallel || chunks <= 1 {
            body(0, n)
            return
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let s = c * chunk
            body(s, min(s + chunk, n))
        }
    }

    // MARK: Phase 2: sense + think

    func sense(_ start: Int, _ end: Int) {
        let size = config.worldSize
        let cg = creatureGrid, fg = foodGrid
        let hearR = config.hearingRange
        let I = Brain.inputs
        for i in start..<end {
            let st = stage[i]
            if st == 0 { continue }
            let p = pos[i]
            let ri = rad[i]
            var pushAcc = V2.zero
            let thinks = (i &+ Int(tick)) % thinkInterval == 0
            if st == Stage.egg.rawValue || !thinks {
                // Eggs, and creatures between thinking ticks, only resolve collisions.
                cg.forEachCell(around: p, radius: ri + 14) { s, e in
                    for k in s..<e {
                        let q = cg.packed[k]
                        let d = torusDelta(V2(q.x, q.y) - p, size)
                        let rr = ri + q.z
                        let d2 = simd_length_squared(d)
                        if d2 < rr * rr && d2 > 1e-6 && Int(cg.items[k]) != i {
                            let dist = d2.squareRoot()
                            pushAcc -= d / dist * (rr - dist) * 0.5
                        }
                    }
                }
                push[i] = pushAcc * config.collisionStiffness
                continue
            }
            let ph = pheno[i]
            let h = heading[i]
            let ch = cos(h), sh = sin(h)
            let viewD = ph.viewDistance
            let halfFov = ph.halfFov
            let sectorScale = Float(Brain.sectors) / (2 * halfFov)
            let inp = inputs + i * I
            for k in 0..<25 { inp[k] = 0 }
            let myHue = genes[i].hue, mySat = genes[i].saturation
            var heard1: Float = 0, heard2: Float = 0
            var bestBite: Float = .infinity
            var biteT: Int32 = -1
            var touchingCreature: Float = 0
            let queryR = max(viewD, hearR) + 14
            // Nearest-first ring search. In crowds we stop after a bounded number of
            // neighbours, which keeps the cost per creature roughly constant.
            var processed = 0
            let contactBound = ri + 14
            cg.forEachRing(around: p, radius: queryR, { s, e in
                for k in s..<e {
                    let q = cg.packed[k]
                    let d = torusDelta(V2(q.x, q.y) - p, size)
                    let d2 = simd_length_squared(d)
                    if d2 > queryR * queryR { continue }
                    let j = Int(cg.items[k])
                    if j == i { continue }
                    processed += 1
                    let dist = d2.squareRoot()
                    let rj = q.z
                    let rr = ri + rj
                    if dist < rr {
                        touchingCreature = 1
                        if dist > 1e-4 { pushAcc -= d / dist * (rr - dist) * 0.5 }
                    }
                    if dist < hearR {
                        let fall = 1 - dist / hearR
                        heard1 += signal1[j] * fall
                        heard2 += signal2[j] * fall
                    }
                    let surface = dist - rj
                    if surface > viewD { continue }
                    // Into the creature's local frame.
                    let lx = d.x * ch + d.y * sh
                    let ly = -d.x * sh + d.y * ch
                    let ang = fastAtan2(ly, lx)
                    if dist < rr + 3 && abs(ang) < 1.1 && dist < bestBite {
                        bestBite = dist
                        biteT = Int32(j)
                    }
                    if abs(ang) > halfFov { continue }
                    var sec = Int((ang + halfFov) * sectorScale)
                    if sec >= Brain.sectors { sec = Brain.sectors - 1 } else if sec < 0 { sec = 0 }
                    let close = 1 - max(surface, 0) / viewD
                    let b = sec * Brain.perSector
                    if close > inp[b + 2] {
                        inp[b + 2] = close
                        inp[b + 3] = (rj - ri) / (rj + ri)
                        inp[b + 4] = clamp(1 - hueDistance(myHue, q.w) * 6 - abs(mySat - genes[j].saturation), -1, 1)
                    }
                }
            }, shouldStop: { bound in
                if bound < contactBound { return false }
                if processed >= 32 { return true }
                // Every sector already sees something nearer than any unvisited creature.
                let needed = 1 - (bound - 13) / viewD
                for s in 0..<Brain.sectors where inp[s * Brain.perSector + 2] < needed { return false }
                return true
            })
            push[i] = pushAcc * config.collisionStiffness
            biteTarget[i] = biteT

            // Food vision with early termination once every sector has a close hit.
            var bestFood: Float = .infinity
            var foodT: Int32 = -1
            let reach = ri + 4
            var nearestPlant = SIMD8<Float>(repeating: .infinity)  // per sector distance (5 used)
            var nearestMeat = SIMD8<Float>(repeating: .infinity)
            let fovFull = halfFov >= .pi * 0.999
            var foodSeen = 0
            let prefersMeat = ph.meatEfficiency > ph.plantEfficiency
            fg.forEachRing(around: p, radius: viewD, { s, e in
                foodSeen += e - s
                for k in s..<e {
                    let q = fg.packed[k]
                    let d = torusDelta(V2(q.x, q.y) - p, size)
                    let d2 = simd_length_squared(d)
                    if d2 > viewD * viewD { continue }
                    let dist = d2.squareRoot()
                    if dist < reach && dist < bestFood {
                        bestFood = dist
                        foodT = fg.items[k]
                    }
                    let lx = d.x * ch + d.y * sh
                    let ly = -d.x * sh + d.y * ch
                    let ang = fastAtan2(ly, lx)
                    if abs(ang) > halfFov { continue }
                    var sec = Int((ang + halfFov) * sectorScale)
                    if sec >= Brain.sectors { sec = Brain.sectors - 1 } else if sec < 0 { sec = 0 }
                    if q.z == 0 {
                        if dist < nearestPlant[sec] { nearestPlant[sec] = dist }
                    } else {
                        if dist < nearestMeat[sec] { nearestMeat[sec] = dist }
                    }
                }
            }, shouldStop: { bound in
                // Stop once each sector's nearest plant is closer than anything still unvisited.
                // Meat is sparse, so we keep searching only while it could still matter.
                // Meat-eaters judge completeness by meat, which is sparse, so they search further.
                if bound < reach { return false }
                if foodSeen >= (prefersMeat ? 140 : 56) { return true }
                if !fovFull && bound < viewD * 0.35 { return false }
                let target = prefersMeat ? nearestMeat : nearestPlant
                for s in 0..<Brain.sectors where target[s] > bound { return false }
                return true
            })
            for s in 0..<Brain.sectors {
                let b = s * Brain.perSector
                if nearestPlant[s] < viewD { inp[b] = 1 - nearestPlant[s] / viewD }
                if nearestMeat[s] < viewD { inp[b + 1] = 1 - nearestMeat[s] / viewD }
            }
            foodTarget[i] = foodT

            let cap = capacityOf(i)
            inp[Brain.inEnergy] = energy[i] / max(cap, 1)
            inp[Brain.inHealth] = health[i] / max(maxHealth(i), 1)
            inp[Brain.inMaturity] = min(age[i] / ph.lifespan, 1)
            let v = vel[i]
            inp[Brain.inSpeed] = (v.x * ch + v.y * sh) / 100
            inp[Brain.inHurt] = hurt[i]
            inp[Brain.inTouchFood] = foodT >= 0 ? 1 : 0
            inp[Brain.inTouchCreature] = touchingCreature
            inp[Brain.inSignal1] = min(heard1, 2)
            inp[Brain.inSignal2] = min(heard2, 2)
            inp[Brain.inClock] = sin(age[i] * ph.clockFrequency * 6.2831853)
            inp[Brain.inBias] = 1

            BrainOps.evaluate(conns: conns + i * Brain.maxConnections,
                              count: Int(connCount[i]), split: Int(connSplit[i]),
                              biases: biases + i * Brain.biasCount,
                              input: inp,
                              hiddenState: hiddenState + i * Brain.hidden,
                              output: outputs + i * Brain.outputs)
        }
    }

    // MARK: Phase 3: act

    func act(_ start: Int, _ end: Int) {
        let c = config
        let dt = c.dt
        let size = c.worldSize
        for i in start..<end {
            let st = stage[i]
            if st == 0 { continue }
            if st == Stage.egg.rawValue {
                pos[i] = torusWrap(pos[i] + push[i], size)
                rad[i] = pheno[i].radiusAdult * Phenotype.growth(0)
                eggTimer[i] -= dt
                lost[i] = 0
                continue
            }
            let ph = pheno[i]
            let out = outputs + i * Brain.outputs
            var thrust = out[Brain.outThrust]
            if thrust < 0 { thrust *= 0.3 }
            let turn = out[Brain.outTurn]
            let growthF = Phenotype.growth(min(age[i] / c.maturityAge, 1))
            let r = ph.radiusAdult * growthF
            rad[i] = r
            let mass = r * r
            var h = heading[i] + turn * ph.maxTurn * dt
            h = wrapAngle(h)
            heading[i] = h
            let dir = V2(cos(h), sin(h))
            var v = vel[i] + dir * (thrust * ph.maxAccel * dt)
            v *= dragFactor
            vel[i] = v
            pos[i] = torusWrap(pos[i] + v * dt + push[i], size)
            let spd = simd_length(v)
            swimPhase[i] += dt * (2 + spd * 0.12) * (1 + abs(thrust))

            let bite = max(out[Brain.outBite], 0)
            let s1 = max(out[Brain.outSignal1], 0), s2 = max(out[Brain.outSignal2], 0)
            signal1[i] = s1; signal2[i] = s2
            var cost = c.baseCost * pow(mass, 0.75)
            cost += c.moveCost * mass * thrust * thrust * (0.35 + 1.3 * genes[i].speed)
            cost += c.turnCost * mass * turn * turn
            cost += ph.visionCost
            cost += c.brainCost * Float(connCount[i])
            cost += c.signalCost * (s1 + s2)
            if bite > 0 && biteTarget[i] >= 0 { cost += c.biteCost * mass * bite }
            cost *= dt
            if assayMode { cost = 0 }
            let mh = c.healthPerMass * mass
            if health[i] < mh && energy[i] > cost {
                let dh = min(mh - health[i], c.healthRegen * mh * dt)
                health[i] += dh
                cost += dh * c.regenCost * 0.1
            }
            if health[i] > mh { health[i] = mh }
            // Growth: move energy into body tissue up to what the current size requires.
            let bodyTarget = c.bodyPerMass * mass
            if body[i] < bodyTarget && !assayMode {
                // Invest only surplus energy, at a bounded rate, keeping a reserve to live on.
                let reserve = c.energyPerMass * mass * 0.3
                let rate = bodyTarget * dt / (c.maturityAge * 0.6)
                let grow = min(bodyTarget - body[i], rate, max(energy[i] - cost - reserve, 0))
                body[i] += grow
                energy[i] -= grow
            }
            let e = energy[i]
            if cost > e {
                lost[i] = max(e, 0)
                energy[i] = 0
            } else {
                lost[i] = cost
                energy[i] = e - cost
            }
            if !assayMode { age[i] += dt }
            hurt[i] *= 0.9
        }
    }

    // MARK: Phase 4: interactions

    func interact() {
        let c = config
        let dt = c.dt
        var lostTotal: Float = 0
        let n = highWater
        for i in 0..<n where stage[i] != 0 {
            lostTotal += lost[i]
        }
        soil += lostTotal

        for i in 0..<n where stage[i] == Stage.alive.rawValue {
            let out = outputs + i * Brain.outputs
            let ph = pheno[i]
            // Eating
            let eat = out[Brain.outEat]
            let f = Int(foodTarget[i])
            if eat > 0 && f >= 0 && f < foodCount && foodEnergy[f] > 0
                && simd_length_squared(torusDelta(foodPos[f] - pos[i], c.worldSize)) < (rad[i] + 6) * (rad[i] + 6) {
                let kind = foodKind[f]
                let eff = kind == 0 ? ph.plantEfficiency : ph.meatEfficiency
                let cap = capacityOf(i)
                if eff > 0.03 && energy[i] < cap {
                    let r = radius(i)
                    var take = min(foodEnergy[f], c.eatRate * r * r * dt * (0.5 + 0.5 * eat))
                    var gain = take * eff
                    if energy[i] + gain > cap {
                        gain = cap - energy[i]
                        take = gain / eff
                    }
                    foodEnergy[f] -= take
                    if assayMode && kind == 0 { assayEaten += Double(take) }
                    energy[i] += gain
                    soil += take - gain
                    eaten[i] += gain
                    lastMeal[i] = age[i]
                    window.intake += gain
                    if kind == 1 { window.meatIntake += gain }
                    if foodEnergy[f] <= 0.01 {
                        soil += max(foodEnergy[f], 0)
                        foodEnergy[f] = 0
                        foodRemoved = true
                        if kind == 0 { plantCount -= 1 } else { meatCount -= 1 }
                    }
                }
            }
            if assayMode { energy[i] = capacityOf(i) * 0.5; continue }
            // Biting
            let bite = out[Brain.outBite]
            let t = Int(biteTarget[i])
            if bite > 0 && t >= 0 && stage[t] != 0 && t != i
                && simd_length(torusDelta(pos[t] - pos[i], c.worldSize)) < rad[i] + rad[t] + 5 {
                let r = radius(i)
                let dmg = c.biteDamage * r * r * ph.biteStrength * bite * dt
                health[t] -= dmg
                hurt[t] = 1
                let drain = min(max(energy[t], 0), dmg * c.biteDrain)
                energy[t] -= drain
                let cap = capacityOf(i)
                let gain = min(drain * ph.meatEfficiency, max(cap - energy[i], 0))
                energy[i] += gain
                soil += drain - gain
                eaten[i] += gain
                window.intake += gain
                window.meatIntake += gain
                if gain > 0 { lastMeal[i] = age[i] }
                if health[t] <= 0 && stage[t] == Stage.alive.rawValue {
                    kills[i] += 1
                }
            }
            // Laying eggs
            if out[Brain.outEgg] > 0 && age[i] >= c.maturityAge && freeList.count > 0 {
                let cap = capacityOf(i)
                let eggE = ph.eggFraction * ph.capacityAdult
                if energy[i] > eggE + cap * c.eggReserve {
                    layEgg(parent: i, energy: eggE)
                }
            }
        }
    }

    func layEgg(parent i: Int, energy eggE: Float) {
        var g = genes[i]
        g.mutate(&rng)
        var b = brainGenome(i)
        BrainOps.mutate(&b, rate: g.mutationRate, &rng)
        var sp = speciesOf[i]
        if sp >= 0 {
            let rec = species[Int(sp)]
            let d = g.distance(to: rec.founderGenes) + b.distance(to: rec.founderBrain)
            if d > config.speciesThreshold {
                sp = newSpecies(parent: sp, genes: g, brain: b)
            }
        }
        let h = heading[i]
        let behind = pos[i] - V2(cos(h), sin(h)) * (radius(i) + 3)
        energy[i] -= eggE
        if spawn(genes: g, brain: b, at: behind, energy: eggE, asEgg: true, species: sp,
                 parent: i, generation: generation[i] + 1) != nil {
            offspring[i] += 1
            window.births += 1
            totalBirths += 1
        } else {
            energy[i] += eggE
        }
    }

    // MARK: Phase 5: lifecycle and environment

    func lifecycle() {
        if assayMode { return }
        let n = highWater
        for i in 0..<n {
            let st = stage[i]
            if st == 0 { continue }
            if st == Stage.egg.rawValue {
                if health[i] <= 0 {
                    die(i, cause: .killed)
                } else if eggTimer[i] <= 0 {
                    stage[i] = Stage.alive.rawValue
                    eggCount -= 1
                    aliveCount += 1
                    age[i] = 0
                    health[i] = maxHealth(i)
                    if collectFX { fx(.hatch, i) }
                }
                continue
            }
            if health[i] <= 0 {
                die(i, cause: .killed)
            } else if energy[i] <= 0 {
                die(i, cause: .starved)
            } else if age[i] > pheno[i].lifespan {
                die(i, cause: .old)
            }
        }
    }

    func die(_ i: Int, cause: DeathCause) {
        let remaining = max(energy[i], 0) + body[i]
        body[i] = 0
        // Bodies are worth more than their stored energy only through that energy itself,
        // so total energy stays conserved.
        if remaining > 0 { addMeat(remaining, at: pos[i], spread: radius(i) * 0.6 + 2) }
        energy[i] = 0
        switch cause {
        case .starved: window.deathsStarved += 1
        case .killed: window.deathsKilled += 1
        case .old: window.deathsOld += 1
        case .removed: break
        }
        if collectFX { fx(cause == .killed ? .kill : .death, i) }
        if stage[i] == Stage.egg.rawValue { eggCount -= 1 } else { aliveCount -= 1 }
        let sp = speciesOf[i]
        if sp >= 0 && Int(sp) < species.count {
            let rec = species[Int(sp)]
            rec.population -= 1
            if rec.population <= 0 {
                rec.population = 0
                rec.extinctTick = tick
                if rec.established {
                    log(.extinction, "「\(rec.name)」が絶滅(\(formatDuration(Double(tick - rec.birthTick) / Double(config.ticksPerSecond)))続いた)", rec.id)
                }
            }
        }
        freeSlot(i)
    }

    func fx(_ kind: FXEvent.Kind, _ i: Int) {
        if fxEvents.count < 4096 {
            fxEvents.append(FXEvent(kind: kind, position: pos[i], hue: genes[i].hue, size: radius(i)))
        }
    }

    func foodDynamics() {
        let c = config
        let dt = c.dt
        // Meat decays back into soil.
        if meatCount > 0 {
            let decay = c.meatDecay * dt
            for k in 0..<foodCount where foodKind[k] == 1 && foodEnergy[k] > 0 {
                let d = foodEnergy[k] * decay + 0.002
                if foodEnergy[k] - d < 0.5 {
                    soil += foodEnergy[k]
                    foodEnergy[k] = 0
                    foodRemoved = true
                    meatCount -= 1
                } else {
                    foodEnergy[k] -= d
                    soil += d
                }
            }
        }
        if foodRemoved { compactFood() }
        if assayMode {
            // Constant, uniform plant density; positions drawn from a dedicated stream.
            while plantCount < assayPlants && foodCount < foodCapacity {
                let k = foodCount
                foodPos[k] = V2(assayRng.float(0, config.worldWidth), assayRng.float(0, config.worldHeight))
                foodEnergy[k] = config.plantEnergy
                foodKind[k] = 0
                foodCount += 1
                plantCount += 1
            }
            return
        }
        // Plants grow from soil.
        if soil > 0 {
            plantAccumulator += soil * c.plantGrowth * seasonFactor * dt
            let cap = c.plantEnergy * 64
            if plantAccumulator > cap { plantAccumulator = cap }
            while plantAccumulator >= c.plantEnergy {
                if !addPlant() { plantAccumulator = 0; break }
                plantAccumulator -= c.plantEnergy
            }
        }
    }

    func compactFood() {
        // Remap table so that food targets held between thinking ticks stay valid.
        let remap = UnsafeMutablePointer<Int32>.allocate(capacity: max(foodCount, 1))
        defer { remap.deallocate() }
        var w = 0
        for k in 0..<foodCount {
            if foodEnergy[k] > 0 {
                if w != k {
                    foodPos[w] = foodPos[k]
                    foodEnergy[w] = foodEnergy[k]
                    foodKind[w] = foodKind[k]
                }
                remap[k] = Int32(w)
                w += 1
            } else {
                remap[k] = -1
            }
        }
        let oldCount = foodCount
        for i in 0..<highWater where stage[i] != 0 {
            let f = Int(foodTarget[i])
            if f >= 0 { foodTarget[i] = f < oldCount ? remap[f] : -1 }
        }
        foodCount = w
        foodRemoved = false
    }

    func repopulate() {
        if assayMode { return }
        let living = aliveCount + eggCount
        guard living < config.minPopulation else { return }
        // Reseed from the survivors when possible so lineages continue; otherwise start fresh.
        var g: Genes
        var b: BrainGenome
        var sp: Int32
        var gen: Int32 = 0
        var parent = -1
        if living > 0 && rng.chance(0.7) {
            var pick = rng.int(living)
            var src = -1
            for i in 0..<highWater where stage[i] != 0 {
                if pick == 0 { src = i; break }
                pick -= 1
            }
            if src < 0 { return }
            g = genes[src]; g.mutate(&rng)
            b = brainGenome(src); BrainOps.mutate(&b, rate: g.mutationRate, &rng)
            sp = speciesOf[src]
            gen = generation[src] + 1
            parent = src
        } else {
            g = Genes.random(&rng)
            b = BrainOps.randomGenome(&rng, connections: config.initialConnections)
            sp = newSpecies(parent: -1, genes: g, brain: b)
        }
        let e = Phenotype(g, config).capacityAdult * 0.3
        guard soil > e else { return }
        let p = V2(rng.float(0, config.worldWidth), rng.float(0, config.worldHeight))
        if spawn(genes: g, brain: b, at: p, energy: e, asEgg: true, species: sp, parent: parent, generation: gen) != nil {
            soil -= e
        }
        if living == 0 {
            log(.collapse, "生き物が全滅した。新たな生命を播種する")
        }
    }

    /// Corrects floating-point drift so that total energy stays exactly constant.
    func rebalanceEnergy() {
        let actual = measuredTotalEnergy() - soil
        soil = config.totalEnergy - actual
    }

    /// Sum of all energy stores. Equal to `config.totalEnergy` up to rounding.
    public func measuredTotalEnergy() -> Float {
        var e: Double = Double(soil) + Double(plantAccumulator) * 0
        for k in 0..<foodCount { e += Double(max(foodEnergy[k], 0)) }
        for i in 0..<highWater where stage[i] != 0 { e += Double(max(energy[i], 0)) + Double(body[i]) }
        return Float(e)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)秒" }
    if s < 3600 { return "\(s / 60)分" }
    return "\(s / 3600)時間\((s % 3600) / 60)分"
}

struct StatWindow {
    var intake: Float = 0
    var meatIntake: Float = 0
    var births: Int32 = 0
    var deathsStarved: Int32 = 0
    var deathsKilled: Int32 = 0
    var deathsOld: Int32 = 0
    var creatureTicks: Double = 0
}
