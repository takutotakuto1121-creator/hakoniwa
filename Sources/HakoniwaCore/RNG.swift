import Foundation

/// Small, fast, deterministic PRNG (SplitMix64). All randomness in the simulation
/// flows through instances of this type so results are reproducible from a seed.
public struct RNG: Sendable, Codable, Equatable {
    public var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    @inline(__always) public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    @inline(__always) public mutating func float() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    @inline(__always) public mutating func float(_ lo: Float, _ hi: Float) -> Float {
        lo + (hi - lo) * float()
    }

    @inline(__always) public mutating func int(_ n: Int) -> Int {
        Int(next() % UInt64(max(n, 1)))
    }

    @inline(__always) public mutating func chance(_ p: Float) -> Bool { float() < p }

    /// Standard normal sample (Box-Muller).
    @inline(__always) public mutating func gaussian() -> Float {
        let u1 = max(float(), 1e-7)
        let u2 = float()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    /// Derives an independent stream from this generator's seed and a key.
    public static func hash(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var r = RNG(seed: a ^ (b &* 0xD6E8_FEB8_6659_FD93))
        return r.next()
    }
}
