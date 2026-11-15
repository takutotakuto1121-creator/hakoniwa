import Foundation

/// Heritable scalar traits. Every gene is stored normalized to [0, 1].
public struct Genes: Sendable, Equatable {
    public static let count = 16
    public var v: SIMD16<Float>

    public init(_ v: SIMD16<Float>) { self.v = v }

    public var size: Float { get { v[0] } set { v[0] = newValue } }
    /// 0 = strict herbivore, 1 = strict carnivore.
    public var diet: Float { get { v[1] } set { v[1] = newValue } }
    public var hue: Float { get { v[2] } set { v[2] = newValue } }
    public var saturation: Float { get { v[3] } set { v[3] = newValue } }
    public var viewAngle: Float { get { v[4] } set { v[4] = newValue } }
    public var viewDistance: Float { get { v[5] } set { v[5] = newValue } }
    public var speed: Float { get { v[6] } set { v[6] = newValue } }
    public var agility: Float { get { v[7] } set { v[7] = newValue } }
    public var eggSize: Float { get { v[8] } set { v[8] = newValue } }
    public var mutationRate: Float { get { v[9] } set { v[9] = newValue } }
    public var clock: Float { get { v[10] } set { v[10] = newValue } }
    public var segments: Float { get { v[11] } set { v[11] = newValue } }
    public var fins: Float { get { v[12] } set { v[12] = newValue } }
    public var tail: Float { get { v[13] } set { v[13] = newValue } }
    public var pattern: Float { get { v[14] } set { v[14] = newValue } }
    public var eyes: Float { get { v[15] } set { v[15] = newValue } }

    public static let names: [String] = [
        "体の大きさ", "食性", "色相", "彩度", "視野角", "視距離", "速さ", "旋回力",
        "卵の大きさ", "突然変異率", "体内時計", "体節", "ひれ", "尾", "模様", "目",
    ]

    static let distanceWeights: SIMD16<Float> = [2.2, 3.2, 0, 0.4, 0.8, 0.8, 0.9, 0.7,
                                                 0.7, 0.4, 0.3, 0.6, 0.5, 0.5, 0.5, 0.3]

    /// A random primordial genome.
    public static func random(_ rng: inout RNG) -> Genes {
        var g = Genes(SIMD16<Float>(repeating: 0))
        for i in 0..<count { g.v[i] = rng.float() }
        g.size = rng.float(0.15, 0.55)
        g.diet = rng.float(0.0, 0.35)
        g.saturation = rng.float(0.45, 1)
        g.viewAngle = rng.float(0.25, 0.75)
        g.viewDistance = rng.float(0.25, 0.75)
        g.speed = rng.float(0.25, 0.75)
        g.agility = rng.float(0.25, 0.75)
        g.eggSize = rng.float(0.25, 0.6)
        g.mutationRate = rng.float(0.35, 0.65)
        return g
    }

    /// Per-gene mutation probability implied by the mutation-rate gene.
    public var mutationProbability: Float { 0.02 + 0.22 * mutationRate * mutationRate }

    public mutating func mutate(_ rng: inout RNG) {
        let p = mutationProbability
        for i in 0..<Genes.count where rng.chance(p) {
            let sigma: Float = (i == 2) ? 0.025 : 0.07
            var x = v[i] + rng.gaussian() * sigma
            if i == 2 {
                x -= x.rounded(.down)  // hue wraps around
            } else {
                // Reflect at the bounds so values do not pile up at 0 or 1.
                if x < 0 { x = -x }
                if x > 1 { x = 2 - x }
                x = clamp01(x)
            }
            v[i] = x
        }
    }

    public func distance(to o: Genes) -> Float {
        var total: Float = 0
        for i in 0..<Genes.count where i != 2 {
            total += abs(v[i] - o.v[i]) * Genes.distanceWeights[i]
        }
        return total + hueDistance(hue, o.hue) * 4
    }
}

/// Values derived from genes once at birth and cached for the hot loops.
public struct Phenotype: Sendable {
    public var radiusAdult: Float
    public var massAdult: Float
    public var halfFov: Float
    public var viewDistance: Float
    public var maxAccel: Float
    public var maxTurn: Float
    public var plantEfficiency: Float
    public var meatEfficiency: Float
    public var biteStrength: Float
    public var lifespan: Float
    public var eggFraction: Float
    public var clockFrequency: Float
    public var visionCost: Float
    public var capacityAdult: Float

    public init(_ g: Genes, _ c: SimConfig) {
        radiusAdult = 3.5 + 9.5 * g.size
        massAdult = radiusAdult * radiusAdult
        halfFov = (0.22 + 0.78 * g.viewAngle) * .pi
        viewDistance = 50 + 190 * g.viewDistance
        let sizeFactor = pow(6 / radiusAdult, 0.25)
        let finBoost = 1 + 0.08 * g.fins + 0.05 * g.tail
        maxAccel = (55 + 170 * g.speed) * sizeFactor * finBoost
        maxTurn = (1.6 + 3.8 * g.agility) * sizeFactor * (1 + 0.1 * g.fins)
        // Close to a linear trade-off with a mild generalist penalty, so that the path
        // from herbivore to carnivore has no deep fitness valley.
        plantEfficiency = 0.92 * pow(clamp01(1 - g.diet), 1.15)
        meatEfficiency = 0.96 * pow(clamp01(g.diet), 1.15)
        biteStrength = 0.2 + 1.6 * g.diet
        lifespan = c.lifespanBase + c.lifespanPerSize * g.size
        eggFraction = 0.08 + 0.24 * g.eggSize
        clockFrequency = 0.1 + 2.0 * g.clock
        visionCost = c.visionCost * viewDistance * (halfFov / .pi)
        capacityAdult = c.energyPerMass * massAdult
    }

    /// Fraction of adult size at the given maturity in [0, 1].
    @inline(__always) public static func growth(_ maturity: Float) -> Float { 0.45 + 0.55 * maturity }
}

/// Generates pronounceable katakana names for species.
public enum SpeciesNamer {
    static let heads = ["カ", "キ", "ク", "コ", "サ", "シ", "ス", "ソ", "タ", "チ", "ツ", "ト", "ナ", "ニ", "ヌ",
                        "ノ", "ハ", "ヒ", "フ", "ホ", "マ", "ミ", "ム", "モ", "ヤ", "ユ", "ヨ", "ラ", "リ", "ル",
                        "ロ", "ワ", "ガ", "ギ", "グ", "ゴ", "ザ", "ジ", "ズ", "ダ", "ド", "バ", "ビ", "ブ", "ボ",
                        "パ", "ピ", "プ", "ポ"]
    static let mids = ["ア", "イ", "ウ", "エ", "オ", "ラ", "リ", "ル", "レ", "ロ", "ン", "ナ", "ミ", "モ", "テ",
                       "ク", "シ", "ヴァ", "フィ", "ティ", "ジュ", "キョ", "ピィ", "ッパ", "ッコ"]
    static let tails = ["ラ", "ル", "ロ", "ナ", "ミ", "ス", "ト", "ノ", "ム", "ア", "イ", "ン", "モ", "リ", "ゼ",
                        "ダ", "ポ", "ケ", "ヌ", "ス"]

    /// Substrings that must never appear in a generated name.
    static let blocked = ["チンポ", "チンコ", "チンチン", "マンコ", "ウンコ", "ウンチ", "シネ", "コロス", "クソ", "キチ",
                          "ガイジ", "ブス", "デブ", "ハゲ", "カス", "ゴミ", "バカ", "アホ", "エロ", "セックス", "ポルノ",
                          "ナチ", "ヒトラ", "オナ", "パイパイ", "オッパ", "チクビ", "キンタ", "タマキン", "ペニ", "ヴァギ",
                          "レイプ", "ファック", "ビッチ", "シッコ", "オシッ", "ゲリ", "ベン", "ケツ", "シリ", "マラ"]

    public static func name(_ rng: inout RNG) -> String {
        while true {
            var s = heads[rng.int(heads.count)]
            let n = 1 + rng.int(2)
            for _ in 0..<n { s += mids[rng.int(mids.count)] }
            s += tails[rng.int(tails.count)]
            if !blocked.contains(where: { s.contains($0) }) { return s }
        }
    }
}
