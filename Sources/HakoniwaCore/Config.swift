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
