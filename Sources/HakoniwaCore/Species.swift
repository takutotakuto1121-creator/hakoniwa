import Foundation

/// One node of the phylogenetic tree.
public final class SpeciesRecord: @unchecked Sendable {
    public let id: Int32
    public let parentId: Int32          // -1 for primordial species
    public let name: String
    public let founderGenes: Genes
    public let founderBrain: BrainGenome
    public let birthTick: Int64
    public internal(set) var extinctTick: Int64? = nil
    public internal(set) var population: Int = 0
    public internal(set) var peakPopulation: Int = 0
    public internal(set) var totalBorn: Int = 0
    /// True once the species reached `establishedPopulation` members; only those are reported.
    public internal(set) var established: Bool = false
    public internal(set) var establishedTick: Int64? = nil
    // Mean traits of the living members, refreshed at every stats sample.
    public internal(set) var meanDiet: Float
    public internal(set) var meanSize: Float
    public internal(set) var meanHue: Float
    public internal(set) var meanSaturation: Float
    public internal(set) var maxGeneration: Int32 = 0

    init(id: Int32, parentId: Int32, name: String, genes: Genes, brain: BrainGenome, tick: Int64) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.founderGenes = genes
        self.founderBrain = brain
        self.birthTick = tick
        meanDiet = genes.diet
        meanSize = genes.size
        meanHue = genes.hue
        meanSaturation = genes.saturation
    }

    public var isAlive: Bool { extinctTick == nil }

    public var dietLabel: String {
        if meanDiet < 0.35 { return "草食" }
        if meanDiet < 0.65 { return "雑食" }
        return "肉食"
    }
}

public enum EventKind: Int, Sendable, Codable {
    case speciation, extinction, milestone, firstCarnivore, intervention, collapse
}

public struct WorldEvent: Sendable, Identifiable {
    public var id: Int
    public var tick: Int64
    public var kind: EventKind
    public var message: String
    public var speciesId: Int32?
}

/// A periodic snapshot of ecosystem-wide statistics.
public struct StatSample: Sendable, Codable {
    public var tick: Int64
    public var population: Int32
    public var eggs: Int32
    public var herbivores: Int32
    public var omnivores: Int32
    public var carnivores: Int32
    public var species: Int32
    public var plants: Int32
    public var plantEnergy: Float
    public var meatEnergy: Float
    public var soilEnergy: Float
    public var creatureEnergy: Float
    public var meanSize: Float
    public var meanSpeed: Float
    public var meanViewDistance: Float
    public var meanConnections: Float
    public var meanGeneration: Float
    public var maxGeneration: Int32
    /// Energy absorbed from food per creature per second during the sample window.
    public var intakeRate: Float
    /// Mean seconds a creature needs to eat one plant-pellet's worth of energy.
    public var secondsPerMeal: Float
    public var births: Int32
    public var deathsStarved: Int32
    public var deathsKilled: Int32
    public var deathsOld: Int32
    public var meatIntakeShare: Float
}
