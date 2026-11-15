import Foundation
import HakoniwaCore
import QuartzCore

enum SimSpeed: Int, CaseIterable, Identifiable {
    case x1 = 1, x4 = 4, x16 = 16, x64 = 64, max = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .x1: return "1×"
        case .x4: return "4×"
        case .x16: return "16×"
        case .x64: return "64×"
        case .max: return "最大"
        }
    }
    var multiplier: Double { self == .max ? 0 : Double(rawValue) }
}

/// Value copy of a species record, safe to hand to the UI.
struct SpeciesInfo: Identifiable, Hashable {
    var id: Int32
    var parentId: Int32
    var name: String
    var birthTick: Int64
    var extinctTick: Int64?
    var population: Int
    var peakPopulation: Int
    var totalBorn: Int
    var established: Bool
    var meanDiet: Float
    var meanSize: Float
    var meanHue: Float
    var meanSaturation: Float
    var maxGeneration: Int32
    var dietLabel: String

    init(_ r: SpeciesRecord) {
        id = r.id; parentId = r.parentId; name = r.name; birthTick = r.birthTick; extinctTick = r.extinctTick
        population = r.population; peakPopulation = r.peakPopulation; totalBorn = r.totalBorn
        established = r.established; meanDiet = r.meanDiet; meanSize = r.meanSize; meanHue = r.meanHue
        meanSaturation = r.meanSaturation; maxGeneration = r.maxGeneration; dietLabel = r.dietLabel
    }

    var isAlive: Bool { population > 0 }
}

/// Snapshot of everything the SwiftUI layer shows, produced on the simulation thread.
struct UIUpdate {
    var tick: Int64
    var ticksPerSecond: Float
    var population: Int
    var eggs: Int
    var herbivores: Int
    var omnivores: Int
    var carnivores: Int
    var speciesAlive: Int
    var maxGeneration: Int32
    var season: Float
    var plants: Int
    var meat: Int
    var simRate: Double              // world seconds per wall second
    var samples: [StatSample]?
    var events: [WorldEvent]?
    var species: [SpeciesInfo]?
    var detail: CreatureDetail?
    var detailMissing: Bool
    var lineage: [SpeciesInfo]?
    var worldID: Int
}

/// Owns the World and advances it on a dedicated thread. All World access goes through here.
final class SimulationController: @unchecked Sendable {
    private var world: World
    private let lock = NSLock()
    private var front = RenderSnapshot()
    private var back = RenderSnapshot()
    private var commands: [(World) -> Void] = []
    private var _speed: SimSpeed = .x1
    private var _paused = false
    private var _stepRequests = 0
    private var _selected: UInt64 = 0
    private var running = true
    private var thread: Thread?
    private(set) var publishTime: CFTimeInterval = CACurrentMediaTime()
    private var worldID = 0
    /// Delivered on the main thread.
    var onUpdate: ((UIUpdate) -> Void)?

    init(world: World) {
        self.world = world
        world.collectFX = true
        world.fillRender(front)
    }

    deinit { running = false }

    // MARK: Thread-safe accessors

    var speed: SimSpeed {
        get { lock.lock(); defer { lock.unlock() }; return _speed }
        set { lock.lock(); _speed = newValue; lock.unlock() }
    }
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var selectedUid: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _selected }
        set { lock.lock(); _selected = newValue; lock.unlock() }
    }

    func requestStep(_ n: Int = 1) { lock.lock(); _stepRequests += n; lock.unlock() }

    /// Runs `cmd` on the simulation thread before the next tick.
    func perform(_ cmd: @escaping (World) -> Void) {
        lock.lock(); commands.append(cmd); lock.unlock()
    }

    /// Replaces the running world (new world / loaded file).
    func replaceWorld(_ w: World) {
        perform { [weak self] _ in
            guard let self else { return }
            w.collectFX = true
            self.world = w
            self.worldID += 1
            self.forceUI = true
        }
    }

    /// Gives the renderer exclusive access to the newest snapshot.
    func withFront<T>(_ body: (RenderSnapshot) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(front)
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "hakoniwa.simulation"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() { running = false }

    // MARK: Simulation loop

    private var forceUI = true
    private var sentSamples = -1
    private var sentEventId = -1
    private var lastSpeciesSend: CFTimeInterval = 0
    private var lastSamplesSend: CFTimeInterval = 0
    private var rateWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var rateWindowTicks = 0
    private var simRate: Double = 0

    private func loop() {
        var lastWall = CACurrentMediaTime()
        var debt: Double = 0
        var lastUI: CFTimeInterval = 0
        while running {
            lock.lock()
            let cmds = commands
            commands.removeAll()
            let speed = _speed, paused = _paused
            let steps = _stepRequests
            _stepRequests = 0
            lock.unlock()
            for c in cmds { c(world) }

            let w = world
            let tps = Double(w.config.ticksPerSecond)
            let now = CACurrentMediaTime()
            var ran = 0
            if paused {
                if steps > 0 { w.step(steps); ran = steps }
                debt = 0
            } else if speed == .max {
                let t0 = now
                repeat {
                    w.step(8); ran += 8
                } while CACurrentMediaTime() - t0 < 0.016
            } else {
                debt += (now - lastWall) * tps * speed.multiplier
                debt = min(debt, tps * speed.multiplier * 0.25 + 1)
                let n = Int(debt)
                if n > 0 {
                    let t0 = now
                    while ran < n {
                        let k = min(n - ran, 4)
                        w.step(k); ran += k
                        if CACurrentMediaTime() - t0 > 0.03 { break }
                    }
                    debt -= Double(ran)
                    if ran < n { debt = 0 }  // could not keep up; drop the backlog
                }
            }
            lastWall = now
            rateWindowTicks += ran
            if now - rateWindowStart > 1 {
                simRate = Double(rateWindowTicks) / tps / (now - rateWindowStart)
                rateWindowStart = now
                rateWindowTicks = 0
            }
            if ran > 0 || !cmds.isEmpty { publish(w) }
            if now - lastUI > 1.0 / 12.0 || forceUI {
                lastUI = now
                sendUI(w, now: now)
            }
            if ran == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
    }

    private func publish(_ w: World) {
        w.fillRender(back)
        lock.lock()
        // Effects not yet consumed by the renderer carry over.
        if !front.fx.isEmpty {
            back.fx.insert(contentsOf: front.fx, at: 0)
            front.fx.removeAll(keepingCapacity: true)
        }
        if back.fertility.isEmpty || back.fertilityTick < front.fertilityTick {
            back.fertility = front.fertility
            back.fertilityTick = front.fertilityTick
        }
        swap(&front, &back)
        publishTime = CACurrentMediaTime()
        lock.unlock()
    }

    private func sendUI(_ w: World, now: CFTimeInterval) {
        var herb = 0, omni = 0, carn = 0, eggs = 0
        withFront { snap in
            for c in snap.creatures {
                if c.flags.truncatingRemainder(dividingBy: 2) >= 1 { eggs += 1; continue }
                if c.diet < 0.35 { herb += 1 } else if c.diet < 0.65 { omni += 1 } else { carn += 1 }
            }
        }
        var u = UIUpdate(
            tick: w.tick, ticksPerSecond: w.config.ticksPerSecond,
            population: w.aliveCount, eggs: w.eggCount,
            herbivores: herb, omnivores: omni, carnivores: carn,
            speciesAlive: 0, maxGeneration: w.maxGeneration, season: w.seasonFactor,
            plants: w.plantCount, meat: w.meatCount, simRate: simRate,
            samples: nil, events: nil, species: nil, detail: nil, detailMissing: false, lineage: nil,
            worldID: worldID)
        var alive = 0
        for s in w.species where s.population > 0 { alive += 1 }
        u.speciesAlive = alive
        // Charts are expensive to rebuild, so the history is sent at most once per second.
        if forceUI || (w.samples.count != sentSamples && now - lastSamplesSend > 1.0) {
            u.samples = w.samples
            sentSamples = w.samples.count
            lastSamplesSend = now
        }
        let lastEvent = w.events.last?.id ?? -1
        if forceUI || lastEvent != sentEventId {
            u.events = Array(w.events.suffix(400))
            sentEventId = lastEvent
        }
        if forceUI || now - lastSpeciesSend > 1.0 {
            lastSpeciesSend = now
            u.species = w.species.filter { $0.established || $0.population > 0 }.map(SpeciesInfo.init)
        }
        let sel = selectedUid
        if sel != 0 {
            if let d = w.detail(uid: sel) {
                u.detail = d
                u.lineage = w.lineage(of: d.speciesId).map(SpeciesInfo.init)
            } else {
                u.detailMissing = true
            }
        }
        forceUI = false
        let cb = onUpdate
        DispatchQueue.main.async { cb?(u) }
    }
}
