import Foundation
import HakoniwaCore
import QuartzCore

/// Everything needed to set up one duel: the two teams and the arena they share.
struct DuelSetup {
    var primordial: [(Genes, BrainGenome)]
    var evolved: [(Genes, BrainGenome)]
    var config: SimConfig
    var arenaSeed: UInt64
    var arenaSize: Float = 1200
    /// Same plant density as the standard foraging assay (600 plants in 2400²).
    var plants: Int { Int((600 * (arenaSize / 2400) * (arenaSize / 2400)).rounded()) }
    var roundSeconds: Float = 120
}

/// Gathered plant energy on both sides at the same tick.
struct DuelReading {
    var tick: Int64 = 0
    var left: Double = 0
    var right: Double = 0
}

/// Runs two arena worlds (primordial on the left, evolved on the right) in exact lockstep.
///
/// Each arena lives in its own `SimulationController` (its own thread, World never shared);
/// a driver thread hands both the same batches of ticks as commands, and each batch reports
/// the tick and the gathered amount, so the k-th reports of both sides describe the same moment.
final class DuelSession: @unchecked Sendable {
    let left: SimulationController
    let right: SimulationController
    let setup: DuelSetup
    let roundTicks: Int
    let ticksPerSecond: Double

    private let lock = NSLock()
    private var _multiplier: Double = 4
    private var _paused = false
    private var running = true
    private var issued = 0
    private var leftReports: [(Int64, Double)] = []
    private var rightReports: [(Int64, Double)] = []
    private var _latest = DuelReading()
    /// One point per world second, for the chart.
    private var _history: [DuelReading] = [DuelReading()]

    init(_ s: DuelSetup) {
        setup = s
        let lw = World.makeArena(s.primordial, base: s.config, seed: s.arenaSeed, size: s.arenaSize, plants: s.plants)
        let rw = World.makeArena(s.evolved, base: s.config, seed: s.arenaSeed, size: s.arenaSize, plants: s.plants)
        left = SimulationController(world: lw)
        right = SimulationController(world: rw)
        ticksPerSecond = Double(s.config.ticksPerSecond)
        roundTicks = Int(Double(s.roundSeconds) * ticksPerSecond)
        for c in [left, right] {
            c.externalClock = true
            c.speed = .x4
        }
    }

    func start() {
        left.start()
        right.start()
        let t = Thread { [weak self] in self?.drive() }
        t.name = "hakoniwa.duel"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        left.stop()
        right.stop()
    }

    /// World seconds per wall second.
    var multiplier: Double {
        get { lock.lock(); defer { lock.unlock() }; return _multiplier }
        set {
            lock.lock(); _multiplier = newValue; lock.unlock()
            // The renderers interpolate motion only at 1× and 4×.
            let s: SimSpeed = newValue <= 1 ? .x1 : (newValue <= 4 ? .x4 : .x16)
            left.speed = s
            right.speed = s
        }
    }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set {
            lock.lock(); _paused = newValue; lock.unlock()
            left.paused = newValue
            right.paused = newValue
        }
    }

    var latest: DuelReading { lock.lock(); defer { lock.unlock() }; return _latest }
    var history: [DuelReading] { lock.lock(); defer { lock.unlock() }; return _history }
    var finished: Bool { latest.tick >= Int64(roundTicks) }

    /// Advances both arenas by `ticks` at once (used by automated captures).
    func advanceNow(_ ticks: Int) {
        lock.lock()
        let n = max(0, min(ticks, roundTicks - issued))
        issued += n
        lock.unlock()
        if n > 0 { issue(n) }
    }

    // MARK: Driver

    private func drive() {
        var last = CACurrentMediaTime()
        var debt: Double = 0
        while true {
            lock.lock()
            let run = running, paused = _paused, mult = _multiplier
            let remaining = roundTicks - issued
            lock.unlock()
            if !run { break }
            let now = CACurrentMediaTime()
            if paused || remaining <= 0 {
                debt = 0
            } else {
                debt += (now - last) * ticksPerSecond * mult
                debt = min(debt, ticksPerSecond * mult * 0.25 + 1)
                let n = min(Int(debt), remaining)
                if n > 0 {
                    debt -= Double(n)
                    lock.lock(); issued += n; lock.unlock()
                    issue(n)
                }
            }
            last = now
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    private func issue(_ n: Int) {
        left.perform { [weak self] w in
            w.step(n)
            self?.report(left: true, w.tick, w.arenaGathered)
        }
        right.perform { [weak self] w in
            w.step(n)
            self?.report(left: false, w.tick, w.arenaGathered)
        }
    }

    private func report(left isLeft: Bool, _ tick: Int64, _ gathered: Double) {
        lock.lock(); defer { lock.unlock() }
        if isLeft { leftReports.append((tick, gathered)) } else { rightReports.append((tick, gathered)) }
        let common = min(leftReports.count, rightReports.count)
        guard common > 0 else { return }
        let tps = Int64(ticksPerSecond.rounded())
        for k in 0..<common {
            let l = leftReports[k], r = rightReports[k]
            let reading = DuelReading(tick: l.0, left: l.1, right: r.1)
            // Keep one point per world second (and the final one).
            if let prev = _history.last, l.0 / tps > prev.tick / tps || l.0 >= Int64(roundTicks) {
                _history.append(reading)
            }
            _latest = reading
        }
        leftReports.removeFirst(common)
        rightReports.removeFirst(common)
    }
}
