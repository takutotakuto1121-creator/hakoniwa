import Foundation

/// All tunable parameters of the simulation. Units: distance in world units,
/// time in seconds of world time, energy in arbitrary energy units.
public struct SimConfig: Codable, Sendable, Equatable {
    // World
    public var worldWidth: Float = 4000
    public var worldHeight: Float = 4000
    public var ticksPerSecond: Float = 20
    /// Total energy in the closed system.
    public var totalEnergy: Float = 3_000_000
    public var initialCreatures: Int = 900
    public var minPopulation: Int = 120
    public var maxCreatures: Int = 8192

    // Physics
    public var drag: Float = 2.2
    public var collisionStiffness: Float = 0.5

    // Plants
    public var plantEnergy: Float = 40
    public var maxPlants: Int = 26000
    /// Fraction of soil energy that becomes plants per second.
    public var plantGrowth: Float = 0.05
    public var seasonPeriod: Float = 1200   // seconds
    public var seasonAmplitude: Float = 0.45
    public var fertilityDriftPeriod: Float = 3600
    public var fertilityContrast: Float = 2.2

    // Meat
    public var meatChunk: Float = 60
    public var meatDecay: Float = 0.006     // fraction per second
    public var maxMeat: Int = 12000

    // Metabolism
    public var energyPerMass: Float = 30
    /// Energy locked in body tissue per unit of mass (released as meat on death).
    public var bodyPerMass: Float = 15
    public var baseCost: Float = 0.55        // * mass^0.75 per second
    public var moveCost: Float = 0.12        // * mass * thrust^2 per second
    public var turnCost: Float = 0.02
    public var visionCost: Float = 0.0045    // * viewDist * fovFraction per second
    public var brainCost: Float = 0.012      // per connection per second
    public var biteCost: Float = 0.08        // * mass per second while biting
    public var signalCost: Float = 0.5
    public var healthRegen: Float = 0.04     // fraction of max health per second
    public var regenCost: Float = 1.0        // energy per health point

    // Feeding / combat
    public var eatRate: Float = 3.0          // * mass energy per second
    public var biteDamage: Float = 1.2       // * mass per second, scaled by diet
    public var biteDrain: Float = 1.5        // energy drained per damage point
    public var healthPerMass: Float = 4

    // Life cycle
    public var maturityAge: Float = 25       // seconds to reach adult size
    public var lifespanBase: Float = 150
    public var lifespanPerSize: Float = 110
    public var eggHatchTime: Float = 6
    public var eggReserve: Float = 0.25      // fraction of capacity kept after laying
    public var hearingRange: Float = 120

    // Evolution
    public var speciesThreshold: Float = 2.4
    public var initialConnections: Int = 26
    /// Number of the 14 primordial lineages that start with a meat-leaning diet gene.
    public var initialMeatEaterLineages: Int = 3
    /// Seconds between random immigrants (0 disables immigration).
    public var immigrationInterval: Float = 15

    public init() {}

    // Decoding tolerates missing keys (older files) by keeping the defaults.
    enum CodingKeys: String, CodingKey {
        case worldWidth
        case worldHeight
        case ticksPerSecond
        case totalEnergy
        case initialCreatures
        case minPopulation
        case maxCreatures
        case drag
        case collisionStiffness
        case plantEnergy
        case maxPlants
        case plantGrowth
        case seasonPeriod
        case seasonAmplitude
        case fertilityDriftPeriod
        case fertilityContrast
        case meatChunk
        case meatDecay
        case maxMeat
        case energyPerMass
        case bodyPerMass
        case baseCost
        case moveCost
        case turnCost
        case visionCost
        case brainCost
        case biteCost
        case signalCost
        case healthRegen
        case regenCost
        case eatRate
        case biteDamage
        case biteDrain
        case healthPerMass
        case maturityAge
        case lifespanBase
        case lifespanPerSize
        case eggHatchTime
        case eggReserve
        case hearingRange
        case speciesThreshold
        case initialConnections
        case initialMeatEaterLineages
        case immigrationInterval
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Float.self, forKey: .worldWidth) { worldWidth = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .worldHeight) { worldHeight = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .ticksPerSecond) { ticksPerSecond = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .totalEnergy) { totalEnergy = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .initialCreatures) { initialCreatures = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .minPopulation) { minPopulation = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .maxCreatures) { maxCreatures = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .drag) { drag = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .collisionStiffness) { collisionStiffness = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .plantEnergy) { plantEnergy = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .maxPlants) { maxPlants = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .plantGrowth) { plantGrowth = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .seasonPeriod) { seasonPeriod = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .seasonAmplitude) { seasonAmplitude = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .fertilityDriftPeriod) { fertilityDriftPeriod = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .fertilityContrast) { fertilityContrast = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .meatChunk) { meatChunk = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .meatDecay) { meatDecay = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .maxMeat) { maxMeat = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .energyPerMass) { energyPerMass = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .bodyPerMass) { bodyPerMass = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .baseCost) { baseCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .moveCost) { moveCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .turnCost) { turnCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .visionCost) { visionCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .brainCost) { brainCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .biteCost) { biteCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .signalCost) { signalCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .healthRegen) { healthRegen = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .regenCost) { regenCost = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .eatRate) { eatRate = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .biteDamage) { biteDamage = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .biteDrain) { biteDrain = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .healthPerMass) { healthPerMass = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .maturityAge) { maturityAge = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .lifespanBase) { lifespanBase = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .lifespanPerSize) { lifespanPerSize = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .eggHatchTime) { eggHatchTime = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .eggReserve) { eggReserve = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .hearingRange) { hearingRange = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .speciesThreshold) { speciesThreshold = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .initialConnections) { initialConnections = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .initialMeatEaterLineages) { initialMeatEaterLineages = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .immigrationInterval) { immigrationInterval = v }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(worldWidth, forKey: .worldWidth)
        try c.encode(worldHeight, forKey: .worldHeight)
        try c.encode(ticksPerSecond, forKey: .ticksPerSecond)
        try c.encode(totalEnergy, forKey: .totalEnergy)
        try c.encode(initialCreatures, forKey: .initialCreatures)
        try c.encode(minPopulation, forKey: .minPopulation)
        try c.encode(maxCreatures, forKey: .maxCreatures)
        try c.encode(drag, forKey: .drag)
        try c.encode(collisionStiffness, forKey: .collisionStiffness)
        try c.encode(plantEnergy, forKey: .plantEnergy)
        try c.encode(maxPlants, forKey: .maxPlants)
        try c.encode(plantGrowth, forKey: .plantGrowth)
        try c.encode(seasonPeriod, forKey: .seasonPeriod)
        try c.encode(seasonAmplitude, forKey: .seasonAmplitude)
        try c.encode(fertilityDriftPeriod, forKey: .fertilityDriftPeriod)
        try c.encode(fertilityContrast, forKey: .fertilityContrast)
        try c.encode(meatChunk, forKey: .meatChunk)
        try c.encode(meatDecay, forKey: .meatDecay)
        try c.encode(maxMeat, forKey: .maxMeat)
        try c.encode(energyPerMass, forKey: .energyPerMass)
        try c.encode(bodyPerMass, forKey: .bodyPerMass)
        try c.encode(baseCost, forKey: .baseCost)
        try c.encode(moveCost, forKey: .moveCost)
        try c.encode(turnCost, forKey: .turnCost)
        try c.encode(visionCost, forKey: .visionCost)
        try c.encode(brainCost, forKey: .brainCost)
        try c.encode(biteCost, forKey: .biteCost)
        try c.encode(signalCost, forKey: .signalCost)
        try c.encode(healthRegen, forKey: .healthRegen)
        try c.encode(regenCost, forKey: .regenCost)
        try c.encode(eatRate, forKey: .eatRate)
        try c.encode(biteDamage, forKey: .biteDamage)
        try c.encode(biteDrain, forKey: .biteDrain)
        try c.encode(healthPerMass, forKey: .healthPerMass)
        try c.encode(maturityAge, forKey: .maturityAge)
        try c.encode(lifespanBase, forKey: .lifespanBase)
        try c.encode(lifespanPerSize, forKey: .lifespanPerSize)
        try c.encode(eggHatchTime, forKey: .eggHatchTime)
        try c.encode(eggReserve, forKey: .eggReserve)
        try c.encode(hearingRange, forKey: .hearingRange)
        try c.encode(speciesThreshold, forKey: .speciesThreshold)
        try c.encode(initialConnections, forKey: .initialConnections)
        try c.encode(initialMeatEaterLineages, forKey: .initialMeatEaterLineages)
        try c.encode(immigrationInterval, forKey: .immigrationInterval)
    }

    public var dt: Float { 1 / ticksPerSecond }
    public var worldSize: V2 { V2(worldWidth, worldHeight) }

    /// Preset used by tests: small, fast world.
    public static var small: SimConfig {
        var c = SimConfig()
        c.worldWidth = 1600
        c.worldHeight = 1600
        c.totalEnergy = 520_000
        c.initialCreatures = 160
        c.minPopulation = 30
        c.maxPlants = 4000
        c.maxMeat = 3000
        c.maxCreatures = 2048
        return c
    }
}
