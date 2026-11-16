import HakoniwaCore
import QuartzCore

// The screen saver compiles the app's renderer (`Sources/Hakoniwa/Render`) and simulation
// controller as-is. The renderer refers to two app-only types; these minimal stand-ins keep it
// compiling without pulling in SwiftUI, the inspector or the audio engine.
// They must provide every member `Renderer.swift` uses (scripts/build-saver.sh fails otherwise).

/// Stand-in for the app's UI model: nothing is selected, followed or inspected.
final class AppModel {
    var selectedUid: UInt64 = 0
    var following = false
    var detail: CreatureDetail?
    var showVision = false
}

/// Stand-in for the app's generative audio: the screen saver is silent.
final class SoundEngine {
    static let shared = SoundEngine()
    func observe(fx: [FXEvent], camera: Camera, creatures: UnsafePointer<CreatureInstance>, count: Int,
                 paused: Bool, now: CFTimeInterval) {}
}
