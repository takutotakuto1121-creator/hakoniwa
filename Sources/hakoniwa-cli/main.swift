import Foundation
import HakoniwaCore

// Headless driver for the hakoniwa simulation.
//
//   hakoniwa-cli run   [--seed N] [--hours H] [--report MIN] [--small] [--save PATH] [--load PATH] [--csv PATH]
//   hakoniwa-cli bench [--seed N] [--seconds S] [--small]

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

let seed = UInt64(option("--seed") ?? "1") ?? 1
var config = flag("--small") ? SimConfig.small : SimConfig()
if let s = option("--set") {
    // --set key=value,key=value for quick parameter sweeps
    var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(config))) as? [String: Any] ?? [:]
    for pair in s.split(separator: ",") {
        let kv = pair.split(separator: "=")
        if kv.count == 2, let v = Double(kv[1]) { dict[String(kv[0])] = v }
    }
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let c = try? JSONDecoder().decode(SimConfig.self, from: data) {
        config = c
    }
}

func header() -> String {
    "  time    pop  eggs   H/O/C            spp  plants  soil%  gen  intake  s/meal  size  spd  view  conn  starve/kill/old  meat%  meatE%  bodyE% tps"
}

func line(_ w: World, _ s: StatSample, _ tps: Double) -> String {
    let t = Double(s.tick) / Double(w.config.ticksPerSecond)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
    let soilPct = s.soilEnergy / w.config.totalEnergy * 100
    return String(format: "%3d:%02d  %5d %5d  %5d/%4d/%4d  %5d  %6d  %5.1f %4d  %6.2f  %6.1f  %.2f %.2f  %.2f %5.1f  %5d/%4d/%4d  %5.1f  %5.1f  %5.1f %6.0f",
                  h, m, s.population, s.eggs, s.herbivores, s.omnivores, s.carnivores, s.species, s.plants,
                  soilPct, s.maxGeneration, s.intakeRate, s.secondsPerMeal, s.meanSize, s.meanSpeed,
                  s.meanViewDistance, s.meanConnections, s.deathsStarved, s.deathsKilled, s.deathsOld,
                  s.meatIntakeShare * 100, s.meatEnergy / w.config.totalEnergy * 100, s.creatureEnergy / w.config.totalEnergy * 100, tps)
}

switch command {
case "run":
    let hours = Double(option("--hours") ?? "1") ?? 1
    let reportMinutes = Double(option("--report") ?? "5") ?? 5
    let world: World
    if let path = option("--load") {
        world = try World.load(from: URL(fileURLWithPath: path))
        print("loaded \(path) at tick \(world.tick)")
    } else {
        world = World(config: config, seed: seed)
    }
    let totalTicks = Int64(hours * 3600 * Double(world.config.ticksPerSecond))
    let reportTicks = max(Int64(reportMinutes * 60 * Double(world.config.ticksPerSecond)), world.sampleInterval)
    let endTick = world.tick + totalTicks
    print(header())
    var last = Date()
    var lastTick = world.tick
    while world.tick < endTick {
        let n = Int(min(reportTicks - world.tick % reportTicks, endTick - world.tick))
        world.step(n)
        if let s = world.samples.last, world.tick % reportTicks == 0 || world.tick >= endTick {
            let now = Date()
            let tps = Double(world.tick - lastTick) / now.timeIntervalSince(last)
            last = now; lastTick = world.tick
            print(line(world, s, tps))
        }
    }
    let established = world.species.filter { $0.established }
    print("species total \(world.species.count), established \(established.count), alive \(world.species.filter { $0.isAlive && $0.population > 0 }.count)")
    for e in world.events.suffix(25) {
        print(String(format: "  [%7.0fs] ", Double(e.tick) / Double(world.config.ticksPerSecond)) + e.message)
    }
    let top = world.species.filter { $0.population > 0 }.sorted { $0.population > $1.population }.prefix(8)
    for sp in top {
        print(String(format: "  %@ pop %4d diet %.2f size %.2f gen %d", sp.name, sp.population, sp.meanDiet, sp.meanSize, sp.maxGeneration))
    }
    if let path = option("--save") {
        try world.save(to: URL(fileURLWithPath: path))
        print("saved \(path)")
    }
    if let path = option("--csv") {
        try world.samplesCSV().write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
    }

case "bench":
    let seconds = Double(option("--seconds") ?? "10") ?? 10
    let world = World(config: config, seed: seed)
    world.step(Int(option("--warmup") ?? "300") ?? 300)
    world.profile = flag("--profile")
    world.parallel = !flag("--serial")
    let start = Date()
    var ticks = 0
    while Date().timeIntervalSince(start) < seconds {
        world.step(30)
        ticks += 30
    }
    let el = Date().timeIntervalSince(start)
    let tps = Double(ticks) / el
    print(String(format: "population %d (eggs %d), food %d: %.0f ticks/s = %.1fx real time",
                 world.aliveCount, world.eggCount, world.foodCount, tps, tps / Double(world.config.ticksPerSecond)))
    if world.profile {
        let total = Double(world.phaseNanos.reduce(0, +))
        for (k, name) in World.phaseNames.enumerated() {
            print(String(format: "  %-10@ %5.1f%%  %.1f us/tick", name, Double(world.phaseNanos[k]) / total * 100,
                         Double(world.phaseNanos[k]) / Double(ticks) / 1000))
        }
    }

case "sweep":
    // Runs several seeds and checks the ecological acceptance criteria.
    let seeds = (option("--seeds") ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
    let hours = Double(option("--hours") ?? "2") ?? 2
    print("seed   pop(min/max/end)   carn% max  omni% max  meat% end  carn>=5% longest  max gen  spp  assay x   wall")
    for sd in seeds {
        let t0 = Date()
        let w = World(config: config, seed: sd)
        w.step(Int(hours * 3600 * Double(config.ticksPerSecond)))
        let pops = w.samples.map { Int($0.population) }
        let fracs = w.samples.map { Double($0.carnivores) / Double(max($0.population, 1)) }
        let omni = w.samples.map { Double($0.omnivores) / Double(max($0.population, 1)) }.max() ?? 0
        let meatShare = Double(w.samples.suffix(30).map { $0.meatIntakeShare }.reduce(0, +)) / 30
        // Longest stretch with carnivores at or above 5% of the population.
        var longest = 0, run = 0
        for f in fracs { run = f >= 0.05 ? run + 1 : 0; longest = max(longest, run) }
        let longestMinutes = Double(longest) * Double(w.sampleInterval) / Double(config.ticksPerSecond) / 60
        let a0 = World.assay(World.primordialGenomes(150, seed: sd, config: config), base: config, seconds: 90)
        let a1 = World.assay(w.sampleGenomes(150), base: config, seconds: 90)
        print(String(format: "%4d   %5d/%5d/%5d   %6.1f    %6.1f     %6.1f   %9.0f min  %7d  %3d  %6.2f  %5.0fs",
                     sd, pops.min() ?? 0, pops.max() ?? 0, w.aliveCount, (fracs.max() ?? 0) * 100, omni * 100,
                     meatShare * 100, longestMinutes,
                     w.maxGeneration, w.samples.last?.species ?? 0, a1.energyPerMinute / max(a0.energyPerMinute, 1e-9),
                     Date().timeIntervalSince(t0)))
        if let dir = option("--save-dir") {
            try w.save(to: URL(fileURLWithPath: dir).appendingPathComponent("sweep-\(sd).hkw"))
        }
    }

case "assay":
    // Compare evolved creatures from a saved world with primordial ones.
    let count = Int(option("--count") ?? "200") ?? 200
    let secs = Float(option("--seconds") ?? "120") ?? 120
    let primordial = World.primordialGenomes(count, seed: seed, config: config)
    let base = World.assay(primordial, base: config, seconds: secs)
    print("generation 0: \(base)")
    if let path = option("--load") {
        let w = try World.load(from: URL(fileURLWithPath: path))
        let evolved = World.assay(w.sampleGenomes(count), base: w.config, seconds: secs)
        print("evolved (t=\(Int(w.worldTime / 60)) min, max gen \(w.maxGeneration)): \(evolved)")
        print(String(format: "improvement: %.2fx faster foraging", evolved.energyPerMinute / max(base.energyPerMinute, 1e-9)))
    }

default:
    print("""
    usage:
      hakoniwa-cli run   [--seed N] [--hours H] [--report MIN] [--small] [--set k=v,...] [--save PATH] [--load PATH] [--csv PATH]
      hakoniwa-cli bench [--seed N] [--seconds S] [--small]
    """)
}
