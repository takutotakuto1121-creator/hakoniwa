import Foundation

public typealias V2 = SIMD2<Float>

@inline(__always) func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(x, lo), hi)
}

@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

/// Rational approximation of tanh, accurate to ~1e-3 and much faster than Foundation.tanh.
@inline(__always) func fastTanh(_ x: Float) -> Float {
    let x = clamp(x, -4.97, 4.97)
    let x2 = x * x
    let a = x * (135135 + x2 * (17325 + x2 * (378 + x2)))
    let b = 135135 + x2 * (62370 + x2 * (3150 + x2 * 28))
    return a / b
}

/// atan2 approximation, max error ~0.005 rad.
@inline(__always) func fastAtan2(_ y: Float, _ x: Float) -> Float {
    let ax = abs(x), ay = abs(y)
    let mx = max(ax, ay)
    if mx == 0 { return 0 }
    let a = min(ax, ay) / mx
    let s = a * a
    var r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a
    if ay > ax { r = 1.57079637 - r }
    if x < 0 { r = 3.14159274 - r }
    if y < 0 { r = -r }
    return r
}

/// Wraps an angle to (-pi, pi].
@inline(__always) func wrapAngle(_ a: Float) -> Float {
    var a = a
    let twoPi: Float = 6.28318531
    if a > .pi || a <= -.pi {
        a -= twoPi * (a / twoPi).rounded()
    }
    return a
}

/// Shortest displacement on a torus of the given size.
@inline(__always) func torusDelta(_ d: V2, _ size: V2) -> V2 {
    var d = d
    let half = size * 0.5
    if d.x > half.x { d.x -= size.x } else if d.x < -half.x { d.x += size.x }
    if d.y > half.y { d.y -= size.y } else if d.y < -half.y { d.y += size.y }
    return d
}

@inline(__always) func torusWrap(_ p: V2, _ size: V2) -> V2 {
    var p = p
    if p.x < 0 { p.x += size.x } else if p.x >= size.x { p.x -= size.x }
    if p.y < 0 { p.y += size.y } else if p.y >= size.y { p.y -= size.y }
    // Guard against large jumps (should not happen with sane velocities).
    if p.x < 0 || p.x >= size.x { p.x = p.x - size.x * (p.x / size.x).rounded(.down) }
    if p.y < 0 || p.y >= size.y { p.y = p.y - size.y * (p.y / size.y).rounded(.down) }
    if p.x >= size.x { p.x = 0 }
    if p.y >= size.y { p.y = 0 }
    return p
}

/// Hue distance on the color wheel, in [0, 0.5].
@inline(__always) func hueDistance(_ a: Float, _ b: Float) -> Float {
    let d = abs(a - b)
    return min(d, 1 - d)
}
