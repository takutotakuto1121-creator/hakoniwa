import HakoniwaCore
import Metal
import simd

/// Draws the selected creature's field of view on top of the world: the fan, the five sector
/// boundaries, and for each sector how strongly it currently sees a plant (green), meat (red)
/// or another creature (white). Values come from the creature's live sensory inputs.
final class VisionOverlay {
    /// Layout must match `VisionUniforms` in `visionShaderSource`.
    struct Uniforms {
        var viewSize = SIMD2<Float>(1, 1)
        var camCenter = SIMD2<Float>(0, 0)
        var offset = SIMD2<Float>(0, 0)
        var origin = SIMD2<Float>(0, 0)
        var zoom: Float = 1
        var pixelRatio: Float = 2
        var heading: Float = 0
        var halfFov: Float = 1
        var viewDistance: Float = 100
        var time: Float = 0
        var alpha: Float = 0
        var bodyRadius: Float = 5
    }

    private let pipeline: MTLRenderPipelineState
    private var u = Uniforms()
    /// Per sector: x = plant, y = meat, z = creature closeness (0...1, smoothed), w = kinship.
    private var sectors = [SIMD4<Float>](repeating: .zero, count: Brain.sectors)
    private var shownUid: UInt64 = 0
    private var visible = false

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba16Float) {
        guard let lib = try? device.makeLibrary(source: visionShaderSource, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "visionVertex")
        d.fragmentFunction = lib.makeFunction(name: "visionFragment")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = pixelFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipeline = p
    }

    /// Call once per frame before encoding. `creature` is the selected creature's render instance
    /// (already in this frame's snapshot), `extrap` the renderer's motion extrapolation in seconds.
    func update(creature: CreatureInstance?, detail: CreatureDetail?, selectedUid: UInt64, enabled: Bool,
                camera: Camera, extrap: Float, time: Float, dt: Float) {
        let target: Float
        if enabled, let c = creature, let d = detail, d.uid == selectedUid, !d.isEgg, d.inputs.count >= Brain.sectors * Brain.perSector {
            if d.uid != shownUid {
                shownUid = d.uid
                u.alpha = 0
                for s in 0..<Brain.sectors { sectors[s] = .zero }
            }
            u.origin = camera.wrap(c.position + c.velocity * extrap)
            u.heading = c.heading
            u.halfFov = d.phenotype.halfFov
            u.viewDistance = d.phenotype.viewDistance
            u.bodyRadius = c.radius
            // Inputs arrive ~12 times a second; ease towards them so the fan breathes smoothly.
            let k = 1 - exp(-dt * 14)
            for s in 0..<Brain.sectors {
                let b = s * Brain.perSector
                let seenCreature = d.inputs[b + 2]
                let t = SIMD4<Float>(d.inputs[b], d.inputs[b + 1], seenCreature, seenCreature > 0 ? d.inputs[b + 4] : 0)
                sectors[s] += (t - sectors[s]) * k
            }
            target = 1
        } else {
            target = 0
        }
        u.alpha += (target - u.alpha) * (1 - exp(-dt * 8))
        if target == 0 && u.alpha < 0.01 { u.alpha = 0 }
        visible = u.alpha > 0.005
        u.viewSize = camera.viewSize
        u.camCenter = camera.center
        u.zoom = camera.zoom
        u.pixelRatio = camera.pixelRatio
        u.time = time
    }

    /// Encodes the overlay for one torus copy of the world.
    func encode(_ enc: MTLRenderCommandEncoder, offset: SIMD2<Float>) {
        guard visible else { return }
        u.offset = offset
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        sectors.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

private let visionShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VisionUniforms {
    float2 viewSize;
    float2 camCenter;
    float2 offset;
    float2 origin;
    float zoom;
    float pixelRatio;
    float heading;
    float halfFov;
    float viewDistance;
    float time;
    float alpha;
    float bodyRadius;
};

struct VisionOut {
    float4 position [[position]];
    float2 local;   // world units relative to the eye
};

constant float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

vertex VisionOut visionVertex(uint vid [[vertex_id]], constant VisionUniforms &u [[buffer(0)]]) {
    float extent = u.viewDistance + 6.0 / u.zoom * u.pixelRatio;
    float2 local = corners[vid] * extent;
    float2 world = u.origin + local + u.offset;
    float2 px = (world - u.camCenter) * u.zoom + u.viewSize * 0.5;
    float2 ndc = px / u.viewSize * 2.0 - 1.0;
    VisionOut o;
    o.position = float4(ndc.x, -ndc.y, 0, 1);
    o.local = local;
    return o;
}

// Anti-aliased thin line: distance in pixels -> coverage.
inline float line(float distPx, float widthPx) {
    return clamp(widthPx * 0.5 + 0.5 - abs(distPx), 0.0, 1.0);
}

fragment float4 visionFragment(VisionOut in [[stage_in]],
                               constant VisionUniforms &u [[buffer(0)]],
                               constant float4 *sec [[buffer(1)]]) {
    float r = length(in.local);
    float R = u.viewDistance;
    float pxPerUnit = u.zoom;
    float pr = u.pixelRatio;
    // Angle relative to the heading, in [-pi, pi].
    float ang = atan2(in.local.y, in.local.x) - u.heading;
    ang = ang - 6.2831853 * floor((ang + 3.1415927) / 6.2831853);
    float hf = u.halfFov;
    float inner = u.bodyRadius * 1.25;

    // Distance (px) outside the fan: angular overshoot at this radius, or beyond the far arc.
    float angOut = max(abs(ang) - hf, 0.0) * r * pxPerUnit;
    float radOut = (r - R) * pxPerUnit;
    float inside = clamp(0.5 - max(angOut, radOut), 0.0, 1.0);
    // Fade the inner part so the creature itself stays clear.
    float innerFade = smoothstep(inner, inner + 10.0, r);

    // Sector index and position inside the sector.
    float secW = 2.0 * hf / 5.0;
    float sf = clamp((ang + hf) / secW, 0.0, 4.999);
    int s = int(sf);
    float4 v = sec[s];
    float3 colPlant = float3(0.25, 1.0, 0.45);
    float3 colMeat = float3(1.0, 0.28, 0.22);
    float3 colLife = float3(0.92, 0.96, 1.0);

    float3 col = float3(0.0);
    float a = 0.0;
    float rn = r / R;

    // Base fan: the faintest wash, a little brighter towards the rim.
    float wash = (0.020 + 0.035 * rn * rn) * inside * innerFade;
    col += float3(0.55, 0.8, 1.0) * wash;
    a += wash * 0.6;

    // Each channel: fill from the eye out to the detected distance, brightest at the target,
    // plus a thin glowing arc where the nearest thing of that kind is.
    float edgeTaper = smoothstep(0.0, 0.18, fract(sf)) * smoothstep(1.0, 0.82, fract(sf));
    float3 strengths = v.xyz;
    for (int c = 0; c < 3; c++) {
        float k = strengths[c];
        if (k <= 0.01) continue;
        float3 cc = c == 0 ? colPlant : (c == 1 ? colMeat : colLife);
        float d = (1.0 - k) * R;                  // distance to what is seen
        float reach = smoothstep(d + 2.0 / pxPerUnit, d - 2.0 / pxPerUnit, r);
        float ramp = pow(clamp(r / max(d, 1.0), 0.0, 1.0), 2.0);
        float fill = reach * (0.025 + 0.11 * ramp * ramp) * k;
        float arc = line((r - d) * pxPerUnit, 1.6 * pr) * edgeTaper;
        float glow = exp(-pow((r - d) * pxPerUnit / (7.0 * pr), 2.0)) * 0.35 * edgeTaper;
        float amt = (fill + (arc * 0.9 + glow) * (0.35 + 0.65 * k)) * inside * innerFade;
        col += cc * amt;
        a += amt * 0.5;
    }

    // Sector boundaries (including the two outer edges), fading out towards the rim.
    float lines = 0.0;
    for (int b = 0; b <= 5; b++) {
        float ba = -hf + secW * float(b);
        float dAng = ang - ba;
        dAng = dAng - 6.2831853 * floor((dAng + 3.1415927) / 6.2831853);
        if (abs(dAng) > 1.5707963) continue;
        float distPx = abs(sin(dAng)) * r * pxPerUnit;
        float outer = (b == 0 || b == 5) ? 1.0 : 0.55;
        lines += line(distPx, 1.0 * pr) * outer * (1.0 - 0.6 * rn) * step(r, R);
    }
    // Far arc.
    float rim = line((r - R) * pxPerUnit, 1.0 * pr) * step(abs(ang), hf + 0.002);
    // A slow sonar pulse travelling outwards along the fan.
    float pulseR = fract(u.time * 0.45) * R;
    float pulse = exp(-pow((r - pulseR) * pxPerUnit / (10.0 * pr), 2.0)) * (1.0 - fract(u.time * 0.45)) * 0.05 * inside;
    float structure = (lines * 0.22 + rim * 0.32) * innerFade + pulse * innerFade;
    col += float3(0.6, 0.85, 1.0) * structure;
    a += structure * 0.5;

    col *= u.alpha;
    a = clamp(a * u.alpha, 0.0, 1.0);
    return float4(col, a);
}
"""#
