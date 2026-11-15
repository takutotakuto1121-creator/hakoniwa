import XCTest
@testable import HakoniwaCore

final class EncyclopediaTests: XCTestCase {
    func testSpeciesMembersCountEveryHatchedCreature() {
        let w = World(config: .small, seed: 11)
        w.step(600)
        let members = w.speciesMembers()
        XCTAssertEqual(members.values.reduce(0) { $0 + $1.count }, w.aliveCount)
        for m in members.values {
            XCTAssertTrue((0...1).contains(m.meanGenes.hue))
            XCTAssertEqual(w.members(ofSpecies: m.speciesId, limit: 10_000).count, m.count)
        }
    }

    func testStatusFindsLivingCreaturesOnly() {
        let w = World(config: .small, seed: 5)
        w.step(100)
        let some = Set((0..<w.highWater).compactMap { w.stage[$0] != 0 ? w.uid[$0] : nil }.prefix(5))
        let st = w.status(of: some.union([UInt64.max]))
        XCTAssertEqual(Set(st.keys), some)
        if let u = some.first, let i = w.slot(of: u) {
            XCTAssertEqual(st[u]?.generation, w.generation[i])
            XCTAssertEqual(st[u]?.speciesId, w.speciesOf[i])
        }
    }

    func testQueriesDoNotChangeTheWorld() {
        let a = World(config: .small, seed: 3), b = World(config: .small, seed: 3)
        a.step(200); b.step(200)
        _ = a.speciesMembers()
        _ = a.members(ofSpecies: 0)
        _ = a.status(of: [1, 2, 3])
        a.step(200); b.step(200)
        XCTAssertEqual(a.aliveCount, b.aliveCount)
        XCTAssertEqual(a.measuredTotalEnergy(), b.measuredTotalEnergy(), accuracy: 1e-3)
    }

    func testPortraitStandInIsAnAdult() {
        var rng = RNG(seed: 1)
        let g = Genes.random(&rng)
        let d = CreatureDetail.portraitStandIn(genes: g, seed: 9)
        XCTAssertEqual(d.radius, Phenotype(g, SimConfig()).radiusAdult)
        XCTAssertEqual(d.maturity, 1)
        XCTAssertFalse(d.isEgg)
    }
}
