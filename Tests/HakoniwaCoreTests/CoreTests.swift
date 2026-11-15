import XCTest
import simd
@testable import HakoniwaCore

final class MathTests: XCTestCase {
    func testFastTanhIsAccurate() {
        var x: Float = -6
        while x <= 6 {
            XCTAssertEqual(fastTanh(x), tanh(x), accuracy: 2e-3, "x=\(x)")
            x += 0.01
        }
    }

    func testFastAtan2IsAccurate() {
        var rng = RNG(seed: 3)
        for _ in 0..<10_000 {
            let y = rng.float(-10, 10), x = rng.float(-10, 10)
            XCTAssertEqual(fastAtan2(y, x), atan2(y, x), accuracy: 6e-3)
        }
    }

    func testTorusDeltaIsShortest() {
        let size = V2(100, 50)
        XCTAssertEqual(torusDelta(V2(90, 0), size), V2(-10, 0))
        XCTAssertEqual(torusDelta(V2(-45, 30), size), V2(-45, -20))
        XCTAssertEqual(torusWrap(V2(-1, 51), size), V2(99, 1))
    }

    func testWrapAngle() {
        XCTAssertEqual(abs(wrapAngle(3 * .pi)), .pi, accuracy: 1e-5)
        XCTAssertEqual(wrapAngle(-2.5 * .pi), -0.5 * .pi, accuracy: 1e-5)
    }

    func testRNGIsDeterministic() {
        var a = RNG(seed: 42), b = RNG(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
        var c = RNG(seed: 1)
        var sum: Float = 0
        for _ in 0..<10_000 { sum += c.float() }
        XCTAssertEqual(sum / 10_000, 0.5, accuracy: 0.02)
    }
}

final class GeneticsTests: XCTestCase {
    func testMutationKeepsGenesInRange() {
        var rng = RNG(seed: 9)
        var g = Genes.random(&rng)
        g.mutationRate = 1
        for _ in 0..<5_000 {
            g.mutate(&rng)
            for i in 0..<Genes.count {
                XCTAssert(g.v[i] >= 0 && g.v[i] <= 1, "gene \(i) = \(g.v[i])")
            }
        }
    }

    func testBrainMutationKeepsInvariants() {
        var rng = RNG(seed: 5)
        var b = BrainOps.randomGenome(&rng, connections: 40)
        for _ in 0..<2_000 {
            BrainOps.mutate(&b, rate: 1, &rng)
            XCTAssertLessThanOrEqual(b.connections.count, Brain.maxConnections)
            XCTAssertEqual(b.biases.count, Brain.biasCount)
            var lastKey = -1
            for c in b.connections {
                XCTAssert(Brain.isValid(src: Int(c.src), dst: Int(c.dst)))
                // Sorted with hidden targets first and no duplicates.
                XCTAssertGreaterThan(c.key, lastKey)
                lastKey = c.key
                XCTAssert(c.weight.isFinite && abs(c.weight) <= 6)
            }
        }
    }

    func testBrainEvaluationIsBounded() {
        var rng = RNG(seed: 11)
        let b = BrainOps.randomGenome(&rng, connections: 120)
        var conns = b.connections
        let split = conns.firstIndex { Int($0.dst) >= Brain.hidden } ?? conns.count
        var input = [Float](repeating: 0, count: Brain.inputs)
        var hidden = [Float](repeating: 0, count: Brain.hidden)
        var output = [Float](repeating: 0, count: Brain.outputs)
        for _ in 0..<100 {
            for k in 0..<Brain.inputs { input[k] = rng.float(-3, 3) }
            conns.withUnsafeBufferPointer { cp in
                b.biases.withUnsafeBufferPointer { bp in
                    BrainOps.evaluate(conns: cp.baseAddress!, count: cp.count, split: split, biases: bp.baseAddress!,
                                      input: input, hiddenState: &hidden, output: &output)
                }
            }
            for v in hidden + output { XCTAssert(v.isFinite && abs(v) <= 1.0001) }
        }
    }

    func testDistanceIsZeroForIdenticalAndGrowsWithMutation() {
        var rng = RNG(seed: 2)
        let g = Genes.random(&rng)
        let b = BrainOps.randomGenome(&rng, connections: 30)
        XCTAssertEqual(g.distance(to: g), 0)
        XCTAssertEqual(b.distance(to: b), 0)
        var g2 = g, b2 = b
        for _ in 0..<200 { g2.mutate(&rng); BrainOps.mutate(&b2, rate: 0.5, &rng) }
        XCTAssertGreaterThan(g.distance(to: g2) + b.distance(to: b2), 0.5)
    }

    func testSpeciesNamesAvoidBlockedWords() {
        var rng = RNG(seed: 0)
        for _ in 0..<20_000 {
            let n = SpeciesNamer.name(&rng)
            XCTAssertFalse(n.isEmpty)
            for w in SpeciesNamer.blocked { XCTAssertFalse(n.contains(w), n) }
        }
    }
}

final class SpatialGridTests: XCTestCase {
    func testGridFindsEveryNeighbourAcrossWrap() {
        let size = V2(1000, 1000)
        let grid = SpatialGrid(worldSize: size, cellSize: 64, capacity: 500)
        var rng = RNG(seed: 4)
        var pts = (0..<500).map { _ in V2(rng.float(0, 1000), rng.float(0, 1000)) }
        pts[0] = V2(5, 5)
        pts[1] = V2(995, 995)   // neighbour across the corner
        pts.withUnsafeBufferPointer { bp in
            grid.build(count: pts.count, positions: bp.baseAddress!, include: { _ in true },
                       pack: { SIMD4(bp[$0].x, bp[$0].y, 0, 0) })
        }
        for q in [V2(5, 5), V2(500, 500), V2(999, 1)] {
            let radius: Float = 150
            var found = Set<Int>()
            grid.forEachCell(around: q, radius: radius) { s, e in
                for k in s..<e {
                    let i = Int(grid.items[k])
                    XCTAssertEqual(grid.packed[k].x, pts[i].x)
                    if simd_length(torusDelta(pts[i] - q, size)) <= radius { found.insert(i) }
                }
            }
            let expected = Set(pts.indices.filter { simd_length(torusDelta(pts[$0] - q, size)) <= radius })
            XCTAssertEqual(found, expected)
        }
    }

    func testRingSearchVisitsCellsOnce() {
        let size = V2(640, 640)
        let grid = SpatialGrid(worldSize: size, cellSize: 64, capacity: 100)
        var pts = [V2]()
        for y in 0..<10 { for x in 0..<10 { pts.append(V2(Float(x) * 64 + 32, Float(y) * 64 + 32)) } }
        pts.withUnsafeBufferPointer { bp in
            grid.build(count: pts.count, positions: bp.baseAddress!, include: { _ in true },
                       pack: { SIMD4(bp[$0].x, bp[$0].y, 0, 0) })
        }
        var seen = [Int](repeating: 0, count: pts.count)
        grid.forEachRing(around: V2(320, 320), radius: 1000, { s, e in
            for k in s..<e { seen[Int(grid.items[k])] += 1 }
        }, shouldStop: { _ in false })
        XCTAssertTrue(seen.allSatisfy { $0 <= 1 })
        XCTAssertGreaterThan(seen.filter { $0 == 1 }.count, 80)
    }
}

final class WorldTests: XCTestCase {
    func testEnergyIsConserved() {
        let w = World(config: .small, seed: 7)
        let total = w.config.totalEnergy
        XCTAssertEqual(w.measuredTotalEnergy(), total, accuracy: total * 1e-4)
        for _ in 0..<10 {
            w.step(97)  // deliberately not a multiple of the rebalance period
            XCTAssertEqual(w.measuredTotalEnergy(), total, accuracy: total * 2e-3)
        }
    }

    func testDeterministicRegardlessOfThreading() {
        let a = World(config: .small, seed: 123)
        let b = World(config: .small, seed: 123)
        a.parallel = true
        b.parallel = false
        a.step(1500)
        b.step(1500)
        XCTAssertEqual(a.aliveCount, b.aliveCount)
        XCTAssertEqual(a.eggCount, b.eggCount)
        XCTAssertEqual(a.foodCount, b.foodCount)
        XCTAssertEqual(a.species.count, b.species.count)
        XCTAssertEqual(a.soil, b.soil)
        for i in 0..<a.highWater {
            XCTAssertEqual(a.stage[i], b.stage[i])
            if a.stage[i] != 0 {
                XCTAssertEqual(a.pos[i], b.pos[i])
                XCTAssertEqual(a.energy[i], b.energy[i])
            }
        }
    }

    func testSaveLoadRoundTripContinuesIdentically() throws {
        let a = World(config: .small, seed: 99)
        a.step(800)
        let data = try a.serialize()
        let b = try World.deserialize(data)
        XCTAssertEqual(b.tick, a.tick)
        XCTAssertEqual(b.aliveCount, a.aliveCount)
        XCTAssertEqual(b.species.count, a.species.count)
        a.step(400)
        b.step(400)
        XCTAssertEqual(a.aliveCount, b.aliveCount)
        XCTAssertEqual(a.foodCount, b.foodCount)
        XCTAssertEqual(a.soil, b.soil)
        for i in 0..<a.highWater where a.stage[i] != 0 {
            XCTAssertEqual(a.pos[i], b.pos[i])
        }
    }

    func testRejectsForeignFiles() {
        XCTAssertThrowsError(try World.deserialize(Data(repeating: 7, count: 64)))
        XCTAssertThrowsError(try World.deserialize(Data()))
    }

    func testNoNaNsAndPopulationSurvives() {
        let w = World(config: .small, seed: 5)
        for _ in 0..<8 {
            w.step(500)
            XCTAssertGreaterThan(w.aliveCount + w.eggCount, 0)
            for i in 0..<w.highWater where w.stage[i] != 0 {
                XCTAssert(w.pos[i].x.isFinite && w.pos[i].y.isFinite)
                XCTAssert(w.energy[i].isFinite && w.health[i].isFinite)
                XCTAssert(w.pos[i].x >= 0 && w.pos[i].x < w.config.worldWidth)
            }
            XCTAssert(w.soil.isFinite)
        }
        XCTAssertFalse(w.samples.isEmpty)
    }

    func testInterventions() {
        let w = World(config: .small, seed: 8)
        w.step(100)
        let total = w.config.totalEnergy
        w.meteor(at: V2(800, 800), radius: 300)
        let foodBefore = w.plantCount
        w.dropFood(at: V2(800, 800), radius: 50, count: 30)
        XCTAssertGreaterThan(w.plantCount, foodBefore)
        let u = w.spawnCreature(at: V2(400, 400), copying: nil)
        XCTAssertNotNil(u)
        XCTAssertNotNil(w.detail(uid: u!))
        w.remove(uid: u!)
        XCTAssertNil(w.slot(of: u!))
        XCTAssertEqual(w.measuredTotalEnergy(), total, accuracy: total * 2e-3)
        w.step(50)
    }
}

final class FeatureTests: XCTestCase {
    func testWallsBlockCreaturesAndPlants() {
        let w = World(config: .small, seed: 21)
        w.splitContinents()
        // Two full-height walls, each several cells thick.
        XCTAssertGreaterThan(w.walls.count, WallMask.resolution * 2 * 3)
        XCTAssertTrue(w.walls.isWall(V2(w.config.worldWidth / 2, 10)))
        XCTAssertTrue(w.walls.isWall(V2(w.config.worldWidth / 2, w.config.worldHeight / 2)))
        w.step(1200)
        for i in 0..<w.highWater where w.stage[i] != 0 {
            XCTAssertFalse(w.walls.isWall(w.pos[i]), "creature inside wall at \(w.pos[i])")
        }
        for k in 0..<w.foodCount where w.foodKind[k] == 0 {
            XCTAssertFalse(w.walls.isWall(w.foodPos[k]))
        }
        let total = w.config.totalEnergy
        XCTAssertEqual(w.measuredTotalEnergy(), total, accuracy: total * 2e-3)
        w.clearWalls()
        XCTAssertEqual(w.walls.count, 0)
    }

    func testReviveBringsBackExtinctSpecies() {
        let w = World(config: .small, seed: 22)
        w.step(3000)
        guard let extinct = w.species.first(where: { $0.population == 0 }) else {
            return XCTFail("expected at least one extinct species")
        }
        let uids = w.revive(speciesId: extinct.id, at: V2(800, 800), count: 4)
        XCTAssertFalse(uids.isEmpty)
        XCTAssertGreaterThan(extinct.population, 0)
        XCTAssertNil(extinct.extinctTick)
        XCTAssertEqual(w.detail(uid: uids[0])?.speciesId, extinct.id)
        XCTAssertEqual(w.detail(uid: uids[0])?.genes, extinct.founderGenes)
    }

    func testClimateAndPlague() {
        let w = World(config: .small, seed: 23)
        w.step(600)
        w.startClimate(.iceAge, minutes: 1)
        XCTAssertEqual(w.climate.kind, .iceAge)
        w.step(Int(60 * w.config.ticksPerSecond) + 5)
        XCTAssertEqual(w.climate.kind, .normal)
        let before = w.aliveCount
        XCTAssertNotNil(w.plague())
        w.step(Int(50 * w.config.ticksPerSecond))
        XCTAssertLessThan(w.aliveCount, before + 200)
        let total = w.config.totalEnergy
        XCTAssertEqual(w.measuredTotalEnergy(), total, accuracy: total * 2e-3)
    }

    func testBiographyAndHallOfFame() {
        let w = World(config: .small, seed: 24)
        w.step(200)
        var target: UInt64 = 0
        for i in 0..<w.highWater where w.stage[i] == Stage.alive.rawValue { target = w.uid[i]; break }
        w.watch(uid: target)
        XCTAssertEqual(w.biography.count, 1)
        w.step(3000)
        XCTAssertGreaterThan(w.biography.count, 1)
        XCTAssertFalse(w.hallOfFame(.offspring).isEmpty)
        let longevity = w.hallOfFame(.longevity)
        XCTAssertEqual(longevity.map(\.value), longevity.map(\.value).sorted(by: >))
    }

    func testHistoryCaptureAndPersistence() throws {
        let w = World(config: .small, seed: 25)
        w.historyInterval = 200
        w.paintWall(from: V2(100, 100), to: V2(400, 100), radius: 20)
        w.step(1000)
        XCTAssertEqual(w.history.count, 5)
        let f = w.history.last!
        XCTAssertEqual(f.creatureCount, Int(f.population))
        XCTAssertGreaterThan(f.plants.count, 0)
        let inst = f.instance(0)
        XCTAssert(inst.position.x >= 0 && inst.position.x <= w.config.worldWidth)
        let b = try World.deserialize(try w.serialize())
        XCTAssertEqual(b.history.count, w.history.count)
        XCTAssertEqual(b.history.last!.creatures, f.creatures)
        XCTAssertEqual(b.walls.cells, w.walls.cells)
        XCTAssertEqual(b.hallOfFame(.longevity).count, w.hallOfFame(.longevity).count)
    }

    func testArenaIsFairBetweenIdenticalTeams() {
        let genomes = World.primordialGenomes(20, seed: 3, config: .small)
        let a = World.makeArena(genomes, base: .small, seed: 9, size: 1200, plants: 200)
        let b = World.makeArena(genomes, base: .small, seed: 9, size: 1200, plants: 200)
        a.step(600); b.step(600)
        XCTAssertEqual(a.arenaGathered, b.arenaGathered)
    }
}

final class CompatibilityTests: XCTestCase {
    func testConfigDecodingToleratesMissingKeys() throws {
        let json = #"{"worldWidth": 1234, "totalEnergy": 99}"#
        let c = try JSONDecoder().decode(SimConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.worldWidth, 1234)
        XCTAssertEqual(c.totalEnergy, 99)
        XCTAssertEqual(c.immigrationInterval, SimConfig().immigrationInterval)
        let round = try JSONDecoder().decode(SimConfig.self, from: JSONEncoder().encode(SimConfig.small))
        XCTAssertEqual(round, SimConfig.small)
    }
}
