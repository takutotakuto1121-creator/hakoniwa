import Foundation
import HakoniwaCore
import Observation
import QuartzCore

/// Main-thread state for the "god hand" UI (climate, plague, walls).
@Observable
final class GodModel {
    static let shared = GodModel()

    var climate: ClimateKind = .normal
    /// World seconds left in the current climate event.
    var climateRemaining: Double = 0
    /// World seconds the current climate event lasts in total (for the progress ring).
    var climateTotal: Double = 1
    var sickCount = 0
    var wallCount = 0
    /// Extinction tick of species that were brought back, so the card can still tell the story.
    var revivedFrom: [Int32: Int64] = [:]

    var climateProgress: Double { climateTotal > 0 ? min(max(climateRemaining / climateTotal, 0), 1) : 0 }
}

/// Copies god-hand state out of the World on the simulation thread and hands it to
/// the renderer (walls, climate) and the UI (`GodModel`).
final class GodBridge: @unchecked Sendable {
    private let lock = NSLock()

    // Simulation-thread bookkeeping.
    private var seenWorld: ObjectIdentifier?
    private var seenWallVersion = -1
    private var seenClimate: ClimateKind = .normal
    private var climateTotal: Double = 1
    private var lastUI: CFTimeInterval = 0
    private var lastSentClimate: ClimateKind?
    private var lastSentSick = -1
    private var lastSentWalls = -1

    // Shared with the render thread (guarded by `lock`).
    private var _wallField: [Float] = []
    private var _wallSerial = 0
    private var _wallCount = 0
    private var _climate: ClimateKind = .normal
    private var _sick = 0

    /// Called on the simulation thread right after `fillRender(snap)`.
    func capture(_ w: World, into snap: RenderSnapshot) {
        let sick = w.markSickness(snap)
        let id = ObjectIdentifier(w)
        let newWorld = id != seenWorld
        var field: [Float]?
        if newWorld || w.walls.version != seenWallVersion {
            seenWorld = id
            seenWallVersion = w.walls.version
            field = w.walls.signedDistanceField(maxDistance: GodBridge.fieldRange)
        }
        let kind = w.climate.kind
        let remaining = w.climateRemainingSeconds
        if newWorld || kind != seenClimate {
            seenClimate = kind
            climateTotal = max(remaining, 1)
        }
        lock.lock()
        if let f = field {
            _wallField = f
            _wallSerial += 1
            _wallCount = w.walls.count
        }
        _climate = kind
        _sick = sick
        let walls = _wallCount
        lock.unlock()

        // UI at ~4 Hz, or immediately when something visible changes.
        let now = CACurrentMediaTime()
        let changed = kind != lastSentClimate || (sick > 0) != (lastSentSick > 0) || walls != lastSentWalls
        guard changed || now - lastUI > 0.25 else { return }
        lastUI = now
        lastSentClimate = kind
        lastSentSick = sick
        lastSentWalls = walls
        let total = climateTotal
        DispatchQueue.main.async {
            let m = GodModel.shared
            if m.climate != kind { m.climate = kind }
            m.climateRemaining = remaining
            m.climateTotal = total
            if m.sickCount != sick { m.sickCount = sick }
            if m.wallCount != walls { m.wallCount = walls }
        }
    }

    static let fieldRange = 6

    /// The wall distance field if it changed since `serial`.
    func wallField(newerThan serial: Int) -> (serial: Int, field: [Float], count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard _wallSerial != serial else { return nil }
        return (_wallSerial, _wallField, _wallCount)
    }

    var climate: ClimateKind { lock.lock(); defer { lock.unlock() }; return _climate }
    var sickCount: Int { lock.lock(); defer { lock.unlock() }; return _sick }
}
