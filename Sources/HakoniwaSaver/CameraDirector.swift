import Foundation
import HakoniwaCore
import simd

/// Moves the camera like a slow documentary shot: long, eased glides between interesting places
/// with gentle zooms, and now and then a closer shot that follows one creature for a while.
///
/// It only sets `camera.targetCenter` / `targetZoom` once per frame along a smooth path;
/// the renderer's camera then tracks that path.
final class CameraDirector {
    enum Shot {
        /// Eased glide from one place and zoom to another.
        case glide
        /// Follows the creature with this uid.
        case follow(UInt64)
    }

    private(set) var shot: Shot = .glide
    private var rng = SystemRandomNumberGenerator()
    private var time: Double = 0
    private var shotStart: Double = 0
    private var shotLength: Double = 0
    private var fromCenter = V2(0, 0)
    /// Destination relative to `fromCenter` (shortest way round the torus).
    private var travel = V2(0, 0)
    private var fromZoom: Float = 1
    private var toZoom: Float = 1
    /// Low-passed position of the followed creature.
    private var subject: V2?
    private var lastWasFollow = false
    private var started = false

    /// Advances by `dt` seconds and sets the camera targets. `snap` is the newest snapshot.
    func update(dt: Double, camera: Camera, snap: RenderSnapshot) {
        let pr = camera.pixelRatio
        if !started {
            // Open on a wide view of a busy place.
            started = true
            camera.targetCenter = interestingPoint(snap: snap, near: nil, camera: camera) ?? snap.worldSize * 0.5
            camera.targetZoom = wideZoom(camera) * 1.15
            camera.snap()
            startGlide(camera: camera, snap: snap, length: rand(20, 26))
        }
        time += dt
        let t = time - shotStart
        let u = shotLength > 0 ? min(t / shotLength, 1) : 1

        switch shot {
        case .glide:
            let e = Float(smootherstep(u))
            // A slow sideways sway keeps the frame alive at the ends of a glide.
            let sway = V2(Float(sin(time * 0.071)), Float(cos(time * 0.053))) * (18 / max(camera.zoom / pr, 0.3))
            camera.targetCenter = camera.wrap(fromCenter + travel * e + sway * Float(sin(Double.pi * u)))
            camera.targetZoom = exp(log(fromZoom) + (log(toZoom) - log(fromZoom)) * e)
        case .follow(let uid):
            guard let k = snap.uids.firstIndex(of: uid), !isEgg(snap.creatures[k]) else {
                // The subject died, was eaten or left the snapshot: drift on from here.
                startGlide(camera: camera, snap: snap, length: rand(26, 34))
                return
            }
            let p = snap.creatures[k].position
            var s = subject ?? p
            s = camera.wrap(s + camera.torusDelta(p - s) * Float(1 - exp(-dt / 0.9)))
            subject = s
            // Ease onto the subject over the first seconds, then hold it in frame.
            let w = Float(smootherstep(min(t / 7, 1)))
            camera.targetCenter = camera.wrap(fromCenter + camera.torusDelta(s - fromCenter) * w)
            let z = Float(smootherstep(min(t / 9, 1)))
            camera.targetZoom = exp(log(fromZoom) + (log(toZoom) - log(fromZoom)) * z)
        }

        if u >= 1 { nextShot(camera: camera, snap: snap) }
    }

    /// Starts following a creature near the middle of the screen right away (preview tool).
    func followNow(camera: Camera, snap: RenderSnapshot) {
        if !startFollow(camera: camera, snap: snap) { startGlide(camera: camera, snap: snap, length: 20) }
    }

    // MARK: - Shots

    private func nextShot(camera: Camera, snap: RenderSnapshot) {
        if !lastWasFollow && rand(0, 1) < 0.45 && startFollow(camera: camera, snap: snap) { return }
        startGlide(camera: camera, snap: snap, length: rand(28, 40))
    }

    private func startGlide(camera: Camera, snap: RenderSnapshot, length: Double) {
        shot = .glide
        lastWasFollow = false
        subject = nil
        shotStart = time
        shotLength = length
        fromCenter = camera.targetCenter
        fromZoom = camera.targetZoom
        let dest = interestingPoint(snap: snap, near: fromCenter, camera: camera)
            ?? camera.wrap(fromCenter + direction(rand(0, 2 * .pi)) * Float(rand(400, 800)))
        travel = camera.torusDelta(dest - fromCenter)
        let wide = wideZoom(camera), mid = 1.25 * camera.pixelRatio
        toZoom = camera.clampZoom(exp(log(wide) + (log(mid) - log(wide)) * Float(rand(0, 1))))
    }

    @discardableResult
    private func startFollow(camera: Camera, snap: RenderSnapshot) -> Bool {
        guard let uid = pickSubject(camera: camera, snap: snap) else { return false }
        shot = .follow(uid)
        lastWasFollow = true
        subject = nil
        shotStart = time
        shotLength = rand(22, 34)
        fromCenter = camera.targetCenter
        fromZoom = camera.targetZoom
        toZoom = camera.clampZoom(Float(rand(2.0, 2.8)) * camera.pixelRatio)
        return true
    }

    /// A creature in view, preferring carnivores and large animals; nil if none is suitable.
    private func pickSubject(camera: Camera, snap: RenderSnapshot) -> UInt64? {
        let n = snap.creatures.count
        guard n > 0, snap.uids.count == n else { return nil }
        let halfView = camera.viewSize * 0.5 / camera.targetZoom
        var best: UInt64?
        var bestScore: Float = -1
        for _ in 0..<min(n, 160) {
            let k = Int.random(in: 0..<n, using: &rng)
            let c = snap.creatures[k]
            if isEgg(c) || c.maturity < 0.5 { continue }
            let d = camera.torusDelta(c.position - camera.targetCenter)
            if abs(d.x) > halfView.x * 0.7 || abs(d.y) > halfView.y * 0.7 { continue }
            let centred = 1 - min(simd_length(d / halfView), 1)
            let score = c.diet * 1.5 + c.radius / 8 + centred + Float(rand(0, 0.8))
            if score > bestScore { bestScore = score; best = snap.uids[k] }
        }
        return best
    }

    /// Position of a creature at a pleasant distance from `near` (somewhere busy), if any.
    private func interestingPoint(snap: RenderSnapshot, near: V2?, camera: Camera) -> V2? {
        let n = snap.creatures.count
        guard n > 0 else { return nil }
        var fallback: V2?
        for _ in 0..<48 {
            let c = snap.creatures[Int.random(in: 0..<n, using: &rng)]
            if isEgg(c) { continue }
            guard let near else { return c.position }
            let d = simd_length(camera.torusDelta(c.position - near))
            if d > 350 && d < 1100 { return c.position }
            if fallback == nil && d > 150 { fallback = c.position }
        }
        return fallback
    }

    private func wideZoom(_ camera: Camera) -> Float {
        camera.clampZoom(max(camera.minZoom * 1.2, 0.5 * camera.pixelRatio))
    }

    // MARK: - Helpers

    private func isEgg(_ c: CreatureInstance) -> Bool { c.flags.truncatingRemainder(dividingBy: 2) >= 1 }
    private func direction(_ a: Double) -> V2 { V2(Float(cos(a)), Float(sin(a))) }
    private func rand(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }
    private func smootherstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}
