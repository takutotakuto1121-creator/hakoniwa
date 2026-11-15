import Foundation

extension Genes: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var v = SIMD16<Float>(repeating: 0)
        for i in 0..<Genes.count { v[i] = try c.decode(Float.self) }
        self.init(v)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for i in 0..<Genes.count { try c.encode(v[i]) }
    }
}


public enum PersistenceError: Error, CustomStringConvertible {
    case badMagic, unsupportedVersion(Int), truncated, corrupt(String)
    public var description: String {
        switch self {
        case .badMagic: return "hakoniwa の世界ファイルではありません"
        case .unsupportedVersion(let v): return "この版(\(v))の世界ファイルは読み込めません(対応: \(World.fileVersion))"
        case .truncated: return "世界ファイルが途中で切れています"
        case .corrupt(let s): return "世界ファイルが壊れています: \(s)"
        }
    }
}

struct SpeciesDTO: Codable {
    var id: Int32, parentId: Int32, name: String
    var genes: Genes, brain: BrainGenome
    var birthTick: Int64, extinctTick: Int64?
    var population: Int, peak: Int, totalBorn: Int
    var established: Bool, establishedTick: Int64?
    var diet: Float, size: Float, hue: Float, sat: Float, maxGen: Int32
}

struct EventDTO: Codable {
    var id: Int, tick: Int64, kind: EventKind, message: String, speciesId: Int32?
}

struct MetaDTO: Codable {
    var config: SimConfig
    var seed: UInt64
    var tick: Int64
    var rng: RNG
    var nextUid: UInt64
    var soil: Float
    var plantAccumulator: Float
    var highWater: Int
    var freeList: [Int32]
    var aliveCount: Int
    var eggCount: Int
    var foodCount: Int
    var plantCount: Int
    var meatCount: Int
    var maxGeneration: Int32
    var nextEventId: Int
    var firstCarnivoreReported: Bool
    var nextGenerationMilestone: Int32
    var totalBirths: Int
    var species: [SpeciesDTO]
    var events: [EventDTO]
    var samples: [StatSample]
}

private struct Writer {
    var data = Data()
    mutating func raw<T>(_ p: UnsafePointer<T>, _ count: Int) {
        data.append(UnsafeBufferPointer(start: p, count: count))
    }
    mutating func u64(_ v: UInt64) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
}

private struct Reader {
    let data: Data
    var offset = 0
    mutating func u64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw PersistenceError.truncated }
        var v: UInt64 = 0
        withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: data[offset..<offset + 8]) }
        offset += 8
        return UInt64(littleEndian: v)
    }
    mutating func bytes(_ n: Int) throws -> Data {
        guard offset + n <= data.count else { throw PersistenceError.truncated }
        let d = data.subdata(in: offset..<offset + n)
        offset += n
        return d
    }
    mutating func raw<T>(into p: UnsafeMutablePointer<T>, _ count: Int) throws {
        let n = count * MemoryLayout<T>.stride
        let d = try bytes(n)
        d.withUnsafeBytes { src in
            UnsafeMutableRawPointer(p).copyMemory(from: src.baseAddress!, byteCount: n)
        }
    }
}

extension World {
    public static let fileVersion = 1
    static let magic: UInt64 = 0x4448_574B_4E48_4B48  // "HKHNKWHD"

    public func save(to url: URL) throws {
        try serialize().write(to: url, options: .atomic)
    }

    public func serialize() throws -> Data {
        let meta = MetaDTO(
            config: config, seed: seed, tick: tick, rng: rng, nextUid: nextUid, soil: soil,
            plantAccumulator: plantAccumulator, highWater: highWater, freeList: freeList,
            aliveCount: aliveCount, eggCount: eggCount, foodCount: foodCount, plantCount: plantCount,
            meatCount: meatCount, maxGeneration: maxGeneration, nextEventId: nextEventId,
            firstCarnivoreReported: firstCarnivoreReported, nextGenerationMilestone: nextGenerationMilestone,
            totalBirths: totalBirths,
            species: species.map {
                SpeciesDTO(id: $0.id, parentId: $0.parentId, name: $0.name, genes: $0.founderGenes,
                           brain: $0.founderBrain, birthTick: $0.birthTick, extinctTick: $0.extinctTick,
                           population: $0.population, peak: $0.peakPopulation, totalBorn: $0.totalBorn,
                           established: $0.established, establishedTick: $0.establishedTick,
                           diet: $0.meanDiet, size: $0.meanSize, hue: $0.meanHue, sat: $0.meanSaturation,
                           maxGen: $0.maxGeneration)
            },
            events: events.map { EventDTO(id: $0.id, tick: $0.tick, kind: $0.kind, message: $0.message, speciesId: $0.speciesId) },
            samples: samples)
        let metaData = try JSONEncoder().encode(meta)
        var w = Writer()
        let n = highWater
        w.raw(stage, n); w.raw(uid, n); w.raw(parentUid, n); w.raw(speciesOf, n); w.raw(generation, n)
        w.raw(birthTick, n); w.raw(pos, n); w.raw(vel, n); w.raw(heading, n); w.raw(energy, n)
        w.raw(health, n); w.raw(age, n); w.raw(hurt, n); w.raw(signal1, n); w.raw(signal2, n)
        w.raw(swimPhase, n); w.raw(eggTimer, n); w.raw(lastMeal, n); w.raw(kills, n); w.raw(offspring, n)
        w.raw(eaten, n); w.raw(genes, n)
        w.raw(conns, n * Brain.maxConnections); w.raw(connCount, n); w.raw(connSplit, n)
        w.raw(biases, n * Brain.biasCount); w.raw(hiddenState, n * Brain.hidden)
        w.raw(outputs, n * Brain.outputs)
        w.raw(biteTarget, n); w.raw(foodTarget, n); w.raw(inputs, n * Brain.inputs); w.raw(rad, n)
        let f = foodCount
        w.raw(foodPos, f); w.raw(foodEnergy, f); w.raw(foodKind, f)
        let body = try (w.data as NSData).compressed(using: .lzfse) as Data
        var out = Writer()
        out.u64(World.magic)
        out.u64(UInt64(World.fileVersion))
        out.u64(UInt64(metaData.count))
        out.data.append(metaData)
        out.u64(UInt64(body.count))
        out.data.append(body)
        return out.data
    }

    public static func load(from url: URL) throws -> World {
        try deserialize(Data(contentsOf: url))
    }

    public static func deserialize(_ data: Data) throws -> World {
        var r = Reader(data: data)
        guard try r.u64() == magic else { throw PersistenceError.badMagic }
        let version = Int(try r.u64())
        guard version == fileVersion else { throw PersistenceError.unsupportedVersion(version) }
        let metaLen = Int(try r.u64())
        let meta = try JSONDecoder().decode(MetaDTO.self, from: try r.bytes(metaLen))
        let bodyLen = Int(try r.u64())
        let compressed = try r.bytes(bodyLen)
        let body = try (compressed as NSData).decompressed(using: .lzfse) as Data
        guard meta.highWater <= meta.config.maxCreatures else { throw PersistenceError.corrupt("highWater") }

        let w = World(config: meta.config, seed: meta.seed, populate: false)
        guard meta.foodCount <= w.foodCapacity else { throw PersistenceError.corrupt("foodCount") }
        var b = Reader(data: body)
        let n = meta.highWater
        try b.raw(into: w.stage, n); try b.raw(into: w.uid, n); try b.raw(into: w.parentUid, n)
        try b.raw(into: w.speciesOf, n); try b.raw(into: w.generation, n); try b.raw(into: w.birthTick, n)
        try b.raw(into: w.pos, n); try b.raw(into: w.vel, n); try b.raw(into: w.heading, n)
        try b.raw(into: w.energy, n); try b.raw(into: w.health, n); try b.raw(into: w.age, n)
        try b.raw(into: w.hurt, n); try b.raw(into: w.signal1, n); try b.raw(into: w.signal2, n)
        try b.raw(into: w.swimPhase, n); try b.raw(into: w.eggTimer, n); try b.raw(into: w.lastMeal, n)
        try b.raw(into: w.kills, n); try b.raw(into: w.offspring, n); try b.raw(into: w.eaten, n)
        try b.raw(into: w.genes, n)
        try b.raw(into: w.conns, n * Brain.maxConnections); try b.raw(into: w.connCount, n)
        try b.raw(into: w.connSplit, n)
        try b.raw(into: w.biases, n * Brain.biasCount); try b.raw(into: w.hiddenState, n * Brain.hidden)
        try b.raw(into: w.outputs, n * Brain.outputs)
        try b.raw(into: w.biteTarget, n); try b.raw(into: w.foodTarget, n)
        try b.raw(into: w.inputs, n * Brain.inputs); try b.raw(into: w.rad, n)
        let f = meta.foodCount
        try b.raw(into: w.foodPos, f); try b.raw(into: w.foodEnergy, f); try b.raw(into: w.foodKind, f)
        w.tick = meta.tick
        for i in 0..<n where w.stage[i] != 0 {
            w.pheno[i] = Phenotype(w.genes[i], meta.config)
        }
        w.rng = meta.rng
        w.nextUid = meta.nextUid
        w.soil = meta.soil
        w.plantAccumulator = meta.plantAccumulator
        w.highWater = meta.highWater
        w.freeList = meta.freeList
        w.aliveCount = meta.aliveCount
        w.eggCount = meta.eggCount
        w.foodCount = meta.foodCount
        w.plantCount = meta.plantCount
        w.meatCount = meta.meatCount
        w.maxGeneration = meta.maxGeneration
        w.nextEventId = meta.nextEventId
        w.firstCarnivoreReported = meta.firstCarnivoreReported
        w.nextGenerationMilestone = meta.nextGenerationMilestone
        w.totalBirths = meta.totalBirths
        w.species = meta.species.map { d in
            let s = SpeciesRecord(id: d.id, parentId: d.parentId, name: d.name, genes: d.genes, brain: d.brain, tick: d.birthTick)
            s.extinctTick = d.extinctTick
            s.population = d.population
            s.peakPopulation = d.peak
            s.totalBorn = d.totalBorn
            s.established = d.established
            s.establishedTick = d.establishedTick
            s.meanDiet = d.diet; s.meanSize = d.size; s.meanHue = d.hue; s.meanSaturation = d.sat
            s.maxGeneration = d.maxGen
            return s
        }
        w.events = meta.events.map { WorldEvent(id: $0.id, tick: $0.tick, kind: $0.kind, message: $0.message, speciesId: $0.speciesId) }
        w.samples = meta.samples
        return w
    }

    public func samplesCSV() -> String {
        var s = "seconds,population,eggs,herbivores,omnivores,carnivores,species,plants,soil,max_generation,intake_rate,seconds_per_meal,mean_size,mean_speed,mean_view,mean_connections,births,starved,killed,old,meat_share\n"
        for x in samples {
            s += "\(Double(x.tick) / Double(config.ticksPerSecond)),\(x.population),\(x.eggs),\(x.herbivores),\(x.omnivores),\(x.carnivores),\(x.species),\(x.plants),\(x.soilEnergy),\(x.maxGeneration),\(x.intakeRate),\(x.secondsPerMeal),\(x.meanSize),\(x.meanSpeed),\(x.meanViewDistance),\(x.meanConnections),\(x.births),\(x.deathsStarved),\(x.deathsKilled),\(x.deathsOld),\(x.meatIntakeShare)\n"
        }
        return s
    }
}
