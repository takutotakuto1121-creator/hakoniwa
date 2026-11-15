import Foundation
import HakoniwaCore
import simd

/// 2D camera over a toroidal world. Positions are in world units; the view is in pixels
/// with the origin at the top-left corner (y grows downward, like the world).
final class Camera {
    var center = V2(2000, 2000)
    var zoom: Float = 0.5
    var targetCenter = V2(2000, 2000)
    var targetZoom: Float = 0.5
    var viewSize = V2(1280, 800)       // pixels
    var pixelRatio: Float = 2
    var worldSize = V2(4000, 4000)
    let maxZoom: Float = 40

    var minZoom: Float { max(viewSize.x / worldSize.x, viewSize.y / worldSize.y) }

    func clampZoom(_ z: Float) -> Float { min(max(z, minZoom), maxZoom * pixelRatio) }

    /// Smoothly approaches the targets. `dt` in seconds.
    func update(dt: Float) {
        targetZoom = clampZoom(targetZoom)
        let k = 1 - exp(-dt * 12)
        let d = torusDelta(targetCenter - center)
        center = wrap(center + d * k)
        targetCenter = wrap(targetCenter)
        zoom = exp(log(zoom) + (log(targetZoom) - log(zoom)) * k)
        zoom = clampZoom(zoom)
    }

    func snap() {
        targetZoom = clampZoom(targetZoom)
        center = wrap(targetCenter)
        zoom = targetZoom
    }

    func torusDelta(_ d: V2) -> V2 {
        var d = d
        if d.x > worldSize.x / 2 { d.x -= worldSize.x } else if d.x < -worldSize.x / 2 { d.x += worldSize.x }
        if d.y > worldSize.y / 2 { d.y -= worldSize.y } else if d.y < -worldSize.y / 2 { d.y += worldSize.y }
        return d
    }

    func wrap(_ p: V2) -> V2 {
        var p = p
        p.x = p.x - worldSize.x * (p.x / worldSize.x).rounded(.down)
        p.y = p.y - worldSize.y * (p.y / worldSize.y).rounded(.down)
        return p
    }

    /// Converts a point in view pixels (top-left origin) to a wrapped world position.
    func worldPoint(pixel: V2) -> V2 {
        wrap(center + (pixel - viewSize * 0.5) / zoom)
    }

    func pixel(world: V2) -> V2 {
        torusDelta(world - center) * zoom + viewSize * 0.5
    }

    /// Zooms by `factor` keeping the world point under `pixel` fixed.
    func zoom(by factor: Float, at pixel: V2) {
        let anchor = targetCenter + (pixel - viewSize * 0.5) / targetZoom
        targetZoom = clampZoom(targetZoom * factor)
        targetCenter = wrap(anchor - (pixel - viewSize * 0.5) / targetZoom)
    }

    func pan(byPixels d: V2) {
        targetCenter = wrap(targetCenter - d / targetZoom)
        center = wrap(center - d / zoom)
    }

    /// Torus offsets for which a copy of the world intersects the view.
    func visibleOffsets() -> [V2] {
        let half = viewSize * 0.5 / zoom
        var out: [V2] = []
        for oy in [-worldSize.y, 0, worldSize.y] {
            if !(oy < center.y + half.y && oy + worldSize.y > center.y - half.y) { continue }
            for ox in [-worldSize.x, 0, worldSize.x] {
                if ox < center.x + half.x && ox + worldSize.x > center.x - half.x {
                    out.append(V2(ox, oy))
                }
            }
        }
        return out
    }
}
