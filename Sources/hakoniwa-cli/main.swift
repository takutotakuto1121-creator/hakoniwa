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
    "  time    pop  eggs   H/O/C            spp  plants  soil%  gen  intake  s/meal  size  spd  view  conn  starve/kill/old  meat%   tps"
}

func line(_ w: World, _ s: StatSample, _ tps: Double) -> String {
    let t = Double(s.tick) / Double(w.config.ticksPerSecond)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
    let soilPct = s.soilEnergy / w.config.totalEnergy * 100
    return String(format: "%3d:%02d  %5d %5d  %5d/%4d/%4d  %5d  %6d  %5.1f %4d  %6.2f  %6.1f  %.2f %.2f  %.2f %5.1f  %5d/%4d/%4d  %5.1f %6.0f",
                  h, m, s.population, s.eggs, s.herbivores, s.omnivores, s.carnivores, s.species, s.plants,
                  soilPct, s.maxGeneration, s.intakeRate, s.secondsPerMeal, s.meanSize, s.meanSpeed,
                  s.meanViewDistance, s.meanConnections, s.deathsStarved, s.deathsKilled, s.deathsOld,
                  s.meatIntakeShare * 100, tps)
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

default:
    print("""
    usage:
      hakoniwa-cli run   [--seed N] [--hours H] [--report MIN] [--small] [--set k=v,...] [--save PATH] [--load PATH] [--csv PATH]
      hakoniwa-cli bench [--seed N] [--seconds S] [--small]
    """)
}
