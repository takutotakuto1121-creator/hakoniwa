import Foundation

/// Layout of the recurrent neural network every creature carries.
///
/// Node index space for connection sources:
///   0 ..< inputs                 sensory inputs
///   inputs ..< inputs + hidden   hidden neurons (previous tick's value when the
///                                target is a hidden neuron, current value when the
///                                target is an output neuron)
/// Connection targets:
///   0 ..< hidden                 hidden neurons
///   hidden ..< hidden + outputs  output neurons
public enum Brain {
    public static let sectors = 5
    public static let perSector = 5
    public static let inputs = 36
    public static let hidden = 16
    public static let outputs = 7
    public static let maxConnections = 192
    public static let biasCount = hidden + outputs

    // Input indices
    public static let inEnergy = 25
    public static let inHealth = 26
    public static let inMaturity = 27
    public static let inSpeed = 28
    public static let inHurt = 29
    public static let inTouchFood = 30
    public static let inTouchCreature = 31
    public static let inSignal1 = 32
    public static let inSignal2 = 33
    public static let inClock = 34
    public static let inBias = 35

    // Output indices
    public static let outThrust = 0
    public static let outTurn = 1
    public static let outBite = 2
    public static let outEat = 3
    public static let outEgg = 4
    public static let outSignal1 = 5
    public static let outSignal2 = 6

    public static let sectorChannelNames = ["植物", "肉", "生物", "相手の大きさ", "仲間らしさ"]
    public static let sectorNames = ["左後", "左", "正面", "右", "右後"]

    public static let inputNames: [String] = {
        var n: [String] = []
        for s in 0..<sectors {
            for c in sectorChannelNames { n.append("\(c)(\(sectorNames[s]))") }
        }
        n += ["エネルギー", "体力", "成長", "速さ", "痛み", "餌に接触", "生物に接触", "信号1", "信号2", "体内時計", "定数"]
        return n
    }()

    public static let outputNames = ["前進", "旋回", "噛む", "食べる", "産卵", "信号1を出す", "信号2を出す"]

    @inline(__always) static func isValid(src: Int, dst: Int) -> Bool {
        src >= 0 && src < inputs + hidden && dst >= 0 && dst < hidden + outputs
    }
}

/// A single weighted connection. 8 bytes.
public struct Connection: Sendable, Equatable, Codable {
    public var src: UInt8
    public var dst: UInt8
    public var weight: Float

    public init(src: Int, dst: Int, weight: Float) {
        self.src = UInt8(src)
        self.dst = UInt8(dst)
        self.weight = weight
    }

    @inline(__always) var key: Int { Int(dst) << 8 | Int(src) }
}

/// Stand-alone copy of a brain, used for species founders, inspection and serialization.
public struct BrainGenome: Sendable, Equatable, Codable {
    public var connections: [Connection]
    public var biases: [Float]

    /// Distance between two brains: mean absolute weight difference over the union of connections.
    public func distance(to o: BrainGenome) -> Float {
        var total: Float = 0
        var i = 0, j = 0
        let a = connections, b = o.connections
        var n = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && a[i].key < b[j].key) {
                total += abs(a[i].weight); i += 1
            } else if i >= a.count || b[j].key < a[i].key {
                total += abs(b[j].weight); j += 1
            } else {
                total += abs(a[i].weight - b[j].weight); i += 1; j += 1
            }
            n += 1
        }
        var biasDiff: Float = 0
        for k in 0..<min(biases.count, o.biases.count) { biasDiff += abs(biases[k] - o.biases[k]) }
        return total / Float(n + 6) * 0.6 + biasDiff / Float(Brain.biasCount) * 0.3
    }
}

enum BrainOps {
    /// Evaluates one tick of the network.
    @inline(__always)
    static func evaluate(conns: UnsafePointer<Connection>, count: Int, split: Int,
                         biases: UnsafePointer<Float>,
                         input: UnsafePointer<Float>,
                         hiddenState: UnsafeMutablePointer<Float>,
                         output: UnsafeMutablePointer<Float>) {
        let I = Brain.inputs, H = Brain.hidden, O = Brain.outputs
        withUnsafeTemporaryAllocation(of: Float.self, capacity: I + H) { src in
            let s = src.baseAddress!
            for k in 0..<I { s[k] = input[k] }
            for k in 0..<H { s[I + k] = hiddenState[k] }
            withUnsafeTemporaryAllocation(of: Float.self, capacity: H) { acc in
                let a = acc.baseAddress!
                for k in 0..<H { a[k] = biases[k] }
                var c = 0
                while c < split {
                    let cn = conns[c]
                    a[Int(cn.dst)] += cn.weight * s[Int(cn.src)]
                    c += 1
                }
                for k in 0..<H {
                    let v = fastTanh(a[k])
                    hiddenState[k] = v
                    s[I + k] = v
                }
            }
            for k in 0..<O { output[k] = biases[H + k] }
            var c = split
            while c < count {
                let cn = conns[c]
                output[Int(cn.dst) - H] += cn.weight * s[Int(cn.src)]
                c += 1
            }
            for k in 0..<O { output[k] = fastTanh(output[k]) }
        }
    }

    static func randomConnection(_ rng: inout RNG) -> Connection {
        let I = Brain.inputs, H = Brain.hidden, O = Brain.outputs
        // Bias the choice toward input->output and input->hidden links, which make
        // early behaviour possible, while still allowing recurrent wiring.
        let r = rng.float()
        let src: Int, dst: Int
        if r < 0.45 {
            src = rng.int(I); dst = H + rng.int(O)
        } else if r < 0.75 {
            src = rng.int(I); dst = rng.int(H)
        } else if r < 0.92 {
            src = I + rng.int(H); dst = H + rng.int(O)
        } else {
            src = I + rng.int(H); dst = rng.int(H)
        }
        return Connection(src: src, dst: dst, weight: rng.gaussian() * 1.2)
    }

    /// Sorts connections (hidden targets first), removes duplicates and returns the split index.
    static func normalize(_ conns: inout [Connection]) -> Int {
        conns.sort { $0.key < $1.key }
        var out: [Connection] = []
        out.reserveCapacity(conns.count)
        for c in conns {
            if let last = out.last, last.key == c.key { continue }
            out.append(c)
        }
        if out.count > Brain.maxConnections { out.removeLast(out.count - Brain.maxConnections) }
        conns = out
        return conns.firstIndex { Int($0.dst) >= Brain.hidden } ?? conns.count
    }

    static func randomGenome(_ rng: inout RNG, connections n: Int) -> BrainGenome {
        var conns: [Connection] = []
        for _ in 0..<n { conns.append(randomConnection(&rng)) }
        _ = normalize(&conns)
        var biases = [Float](repeating: 0, count: Brain.biasCount)
        for k in 0..<Brain.biasCount { biases[k] = rng.gaussian() * 0.5 }
        // Give the eat and egg drives a mild positive default so the first
        // generation is not entirely sterile or starving.
        biases[Brain.hidden + Brain.outEat] += 0.4
        biases[Brain.hidden + Brain.outEgg] += 0.3
        biases[Brain.hidden + Brain.outThrust] += 0.3
        return BrainGenome(connections: conns, biases: biases)
    }

    static func mutate(_ b: inout BrainGenome, rate: Float, _ rng: inout RNG) {
        let pWeight = 0.04 + 0.5 * rate
        var conns = b.connections
        var i = 0
        while i < conns.count {
            if rng.chance(0.012 + 0.03 * rate) {
                conns.remove(at: i)
                continue
            }
            if rng.chance(pWeight) {
                if rng.chance(0.08) {
                    conns[i].weight = rng.gaussian() * 1.2
                } else {
                    conns[i].weight = clamp(conns[i].weight + rng.gaussian() * 0.3, -6, 6)
                }
            }
            i += 1
        }
        var adds = 0
        while rng.chance(0.25 + 0.4 * rate) && adds < 4 {
            conns.append(randomConnection(&rng))
            adds += 1
        }
        _ = normalize(&conns)
        b.connections = conns
        for k in 0..<b.biases.count where rng.chance(pWeight * 0.6) {
            b.biases[k] = clamp(b.biases[k] + rng.gaussian() * 0.25, -4, 4)
        }
    }
}
