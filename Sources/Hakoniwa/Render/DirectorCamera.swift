import Foundation
import HakoniwaCore
import simd

/// Cinematic camera moves for the demo mode: eased flights between shots, smooth tracking of a
/// subject and a slow push-in while holding. Drives `Camera` directly, one frame at a time.
final class DirectorCamera {
    struct Shot {
        /// Creature to track (0 = fixed point).
        var subject: UInt64 = 0
        /// Where to look when there is no subject, or until the subject is found.
        var anchor: V2
        /// Zoom in points per world unit; ignored for wide shots.
        var zoom: Float = 3
        /// A wide shot of the whole world (zoom follows the window size).
        var wide = false
        /// Zoom multiplier reached at the end of the shot (slow push-in when > 1).
        var push: Float = 1.15
        /// Seconds the shot lasts, including the flight to it.
        var duration: Double = 9
        /// Slow drift in world units per second (wide shots).
        var drift = V2.zero
    }

    private(set) var shot: Shot?
    /// Seconds since the current shot began.
    private(set) var time: Double = 0
    private(set) var flightDuration: Double = 2
    /// True once the subject of the current shot has disappeared (eaten, died).
    private(set) var subjectLost = false

    private var startCenter = V2.zero
    private var startZoom: Float = 1
    private var hop: Float = 0
    // Critically damped follow of the subject, so the camera never jerks with the 10 Hz brain.
    private var follow = V2.zero
    private var followVel = V2.zero
    private var leadVel = V2.zero
    private var hasFollow = false
    private var lastSeen: V2?

    var isFlying: Bool { time < flightDuration }
    var remaining: Double { (shot?.duration ?? 0) - time }

    func begin(_ s: Shot, camera: Camera) {
        shot = s
        time = 0
        subjectLost = false
        startCenter = camera.center
        startZoom = camera.zoom
        hasFollow = false
        lastSeen = nil
        followVel = .zero
        leadVel = .zero
        let goalZoom = baseZoom(s, camera)
        let dist = simd_length(camera.torusDelta(s.anchor - startCenter))
        // Distance in screen heights at the closer of the two zooms: far hops pull back mid-flight.
        let screens = dist * max(goalZoom, startZoom) / max(min(camera.viewSize.x, camera.viewSize.y), 1)
        hop = screens > 1.2 ? min(1.6, 0.55 * log(screens)) : 0
        flightDuration = s.wide || screens < 0.3 ? 2.6 : Double(min(max(1.9 + 0.35 * log(max(screens, 1)), 2.2), 3.6))
    }

    func stop() { shot = nil }

    private func baseZoom(_ s: Shot, _ camera: Camera) -> Float {
        if s.wide {
            // Whole world in view (the torus repeats beyond the edges).
            return camera.minZoom * 1.04
        }
        return s.zoom * camera.pixelRatio
    }

    /// Advances one frame. `subject` is the tracked creature's current position and velocity
    /// (nil when not found).
    func drive(camera: Camera, dt: Float, subject: (position: V2, velocity: V2)?) {
        guard let s = shot else { return }
        time += Double(dt)

        // Where the shot wants to look right now.
        var goal = camera.wrap(s.anchor + s.drift * Float(time))
        if s.subject != 0 {
            let omega: Float = 3.2
            if let sub = subject {
                // Smoothed velocity, fed forward so the spring does not trail a swimming subject.
                leadVel += (sub.velocity - leadVel) * (1 - exp(-dt * 3))
                lastSeen = sub.position
                if !hasFollow { follow = sub.position; followVel = leadVel; hasFollow = true }
            } else if lastSeen != nil {
                subjectLost = true
                leadVel *= exp(-dt * 4)
            }
            if hasFollow {
                // A critically damped spring lags a target moving at v by 2v/ω; aim ahead by that much.
                let target = (lastSeen ?? follow) + leadVel * (2 / omega)
                let d = camera.torusDelta(target - follow)
                // Semi-implicit integration of x'' = ω²(target − x) − 2ωx'.
                followVel += (omega * omega * d - 2 * omega * followVel) * dt
                follow = camera.wrap(follow + followVel * dt)
                goal = follow
            }
        }
        let progress = Float(min(time / max(s.duration, 0.1), 1))
        let goalZoom = baseZoom(s, camera) * pow(s.push, smooth(progress))

        let e = Float(easeInOut(min(time / flightDuration, 1)))
        let center = camera.wrap(startCenter + camera.torusDelta(goal - startCenter) * e)
        var logZoom = log(startZoom) + (log(goalZoom) - log(startZoom)) * e
        logZoom -= hop * sin(.pi * e)
        let zoom = camera.clampZoom(exp(logZoom))

        camera.center = center
        camera.targetCenter = center
        camera.zoom = zoom
        camera.targetZoom = zoom
    }

    private func easeInOut(_ t: Double) -> Double {
        // Quintic smootherstep: zero velocity and acceleration at both ends.
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}
