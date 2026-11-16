import XCTest
import simd
@testable import HakoniwaCore

final class DemoSupportTests: XCTestCase {
    private var small: SimConfig {
        var c = SimConfig()
        c.initialCreatures = 400
        return c
    }

    func testScanFindsRealCreaturesAndCountsMatch() {
        let w = World(config: small, seed: 5)
        w.step(600)
        let scan = w.demoScan()
        XCTAssertEqual(scan.population, w.aliveCount)
        XCTAssertEqual(scan.herbivores + scan.omnivores + scan.carnivores, w.aliveCount)
        XCTAssertGreaterThan(scan.speciesAlive, 0)
        let ws = w.config.worldSize
        for h in scan.highlights {
            XCTAssertNotNil(w.slot(of: h.uid), "\(h.kind) points at a missing creature")
            XCTAssertTrue(h.position.x >= 0 && h.position.x <= ws.x && h.position.y >= 0 && h.position.y <= ws.y)
            switch h.kind {
            case .herd: XCTAssertGreaterThanOrEqual(h.groupCount, 8)
            case .hunt: XCTAssertGreaterThanOrEqual(h.diet, 0.5)
            case .bigCarnivore: XCTAssertGreaterThanOrEqual(h.diet, 0.65)
            case .rareColor: XCTAssertLessThan(h.share, 0.05)
            case .hatch: XCTAssertGreaterThan(h.secondsLeft, 0)
            case .forager: XCTAssertLessThan(h.diet, 0.35)
            }
        }
    }

    func testScanDoesNotChangeTheWorld() {
        let a = World(config: small, seed: 9), b = World(config: small, seed: 9)
        a.step(200); b.step(200)
        for _ in 0..<3 { _ = a.demoScan(); a.step(20); b.step(20) }
        XCTAssertEqual(a.aliveCount, b.aliveCount)
        XCTAssertEqual(a.totalBirths, b.totalBirths)
        XCTAssertEqual(a.soil, b.soil)
    }
}
