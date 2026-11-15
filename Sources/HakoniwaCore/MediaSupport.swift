import Foundation

// Public constructors for the app's media features (creature card portraits), which draw single
// creatures and plants outside the simulation.

extension CreatureInstance {
    public static func make(position: SIMD2<Float>, velocity: SIMD2<Float>, heading: Float, radius: Float, hue: Float,
                            saturation: Float, diet: Float, swimPhase: Float, segments: Float, fins: Float, tail: Float,
                            pattern: Float, eyes: Float, energy: Float, hurt: Float, flags: Float, maturity: Float,
                            signal: Float) -> CreatureInstance {
        CreatureInstance(position: position, velocity: velocity, heading: heading, radius: radius, hue: hue,
                         saturation: saturation, diet: diet, swimPhase: swimPhase, segments: segments, fins: fins,
                         tail: tail, pattern: pattern, eyes: eyes, energy: energy, hurt: hurt, flags: flags,
                         maturity: maturity, signal: signal)
    }
}

extension FoodInstance {
    public static func make(position: SIMD2<Float>, energy: Float, kind: Float) -> FoodInstance {
        FoodInstance(position: position, energy: energy, kind: kind)
    }
}
