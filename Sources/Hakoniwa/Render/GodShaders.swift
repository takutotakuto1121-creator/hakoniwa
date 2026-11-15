// Metal source for the "god hand" layers: walls (rocky reef ridges), the miasma around sick
// creatures and the climate colour grade. Compiled at runtime into its own library.

let godShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct GodUniforms {
    float2 viewSize;     // drawable pixels
    float2 camCenter;
    float2 worldSize;
    float2 offset;       // torus offset for this draw call
    float zoom;          // pixels per world unit
    float time;
    float pixelRatio;
    float extrap;
    float ice;           // 0..1 ice-age strength
    float warm;          // 0..1 warm-period strength
    float wallRes;       // wall grid resolution (cells per side)
    float fieldRange;    // clamp of the distance field, in cells
};

struct CreatureInstance {
    float2 position;
    float2 velocity;
    float heading;
    float radius;
    float hue;
    float saturation;
    float diet;
    float swimPhase;
    float segments;
    float fins;
    float tail;
    float pattern;
    float eyes;
    float energy;
    float hurt;
    float flags;
    float maturity;
    float signal;
};

constant float2 godQuad[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

inline float ghash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 ghash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

inline float2 wrapCell(float2 c, float period) { return c - period * floor(c / period); }

/// Value noise whose lattice repeats every `period` units (so it is seamless on the torus).
inline float pnoise(float2 p, float period) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = ghash12(wrapCell(i, period));
    float b = ghash12(wrapCell(i + float2(1, 0), period));
    float c = ghash12(wrapCell(i + float2(0, 1), period));
    float d = ghash12(wrapCell(i + float2(1, 1), period));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

/// Seamless fBm: `uv` is the position in world-fractions (0..1 wraps), `freq` lattice cells per world.
inline float pfbm(float2 uv, float freq, int octaves) {
    float v = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        v += a * pnoise(uv * freq + float(i) * 17.3, freq);
        norm += a;
        freq *= 2.0;
        a *= 0.5;
    }
    return v / norm;
}

inline float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = ghash12(i), b = ghash12(i + float2(1, 0)), c = ghash12(i + float2(0, 1)), d = ghash12(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

struct GodFSOut {
    float4 position [[position]];
    float2 uv;
};

vertex GodFSOut godFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    GodFSOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// MARK: - Walls

/// Cubic B-spline filtered sample from 4 bilinear taps: smooth (C2) contours and normals.
inline float sampleCubic(texture2d<float> t, float2 uv) {
    constexpr sampler s(address::repeat, filter::linear);
    float2 size = float2(t.get_width(), t.get_height());
    float2 coord = uv * size - 0.5;
    float2 i = floor(coord);
    float2 f = coord - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = (i - 0.5 + w1 / g0) / size;
    float2 h1 = (i + 1.5 + w3 / g1) / size;
    float a = t.sample(s, float2(h0.x, h0.y)).r;
    float b = t.sample(s, float2(h1.x, h0.y)).r;
    float c = t.sample(s, float2(h0.x, h1.y)).r;
    float d = t.sample(s, float2(h1.x, h1.y)).r;
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

/// Signed distance to the reef outline in wall cells (negative inside), with an eroded edge.
inline float reefField(texture2d<float> t, float2 uv, constant GodUniforms &u) {
    float d = sampleCubic(t, uv);
    d += (pfbm(uv, u.wallRes * 0.35, 3) - 0.5) * 1.6;
    d += (pnoise(uv * u.wallRes * 2.0, u.wallRes * 2.0) - 0.5) * 0.28;
    return d;
}

/// Height of the ridge (0 at the outline, ~1 on the crest) plus rocky relief.
inline float reefHeight(float d, float2 uv, constant GodUniforms &u) {
    float inside = max(-d, 0.0);
    float h = 1.0 - exp(-inside * 0.9);
    float rock = pfbm(uv, u.wallRes * 1.2, 3);
    h += (rock - 0.5) * 0.22 * smoothstep(0.0, 0.8, inside);
    return h;
}

/// Cellular (Voronoi) pattern on a seamless lattice: x = distance to the nearest point, y = its id hash,
/// zw = vector from that point to `p`.
inline float4 pcells(float2 p, float period) {
    float2 i = floor(p), f = fract(p);
    float best = 8.0, id = 0.0;
    float2 vec = float2(0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(x, y);
            float2 c = wrapCell(i + g, period);
            float2 o = ghash22(c) * 0.8 + 0.1;
            float d = length(g + o - f);
            if (d < best) { best = d; id = ghash12(c + 11.7); vec = f - g - o; }
        }
    }
    return float4(best, id, vec);
}

fragment float4 reefFragment(GodFSOut in [[stage_in]],
                             constant GodUniforms &u [[buffer(0)]],
                             texture2d<float> field [[texture(0)]]) {
    constexpr sampler s(address::repeat, filter::linear);
    float2 px = in.uv * u.viewSize;
    float2 world = u.camCenter + (px - u.viewSize * 0.5) / u.zoom;
    float2 uv = world / u.worldSize;
    // Cheap rejection far from any wall.
    if (field.sample(s, uv).r > 3.4) return float4(0);

    float cellWorld = u.worldSize.x / u.wallRes;
    float pxPerCell = cellWorld * u.zoom;
    float t = u.time;
    float d = reefField(field, uv, u);
    float aa = max(fwidth(d), 1e-3);
    float cover = smoothstep(aa, -aa, d);

    float3 rgb = float3(0);
    float alpha = 0;

    // Shadow and occlusion on the seabed (light comes from the upper left).
    float2 Lxy = float2(-0.55, -0.62);
    float3 L = normalize(float3(Lxy, 0.5));
    float dShadow = reefField(field, uv + Lxy * 1.1 / u.wallRes, u);
    float shadow = smoothstep(0.7, -0.9, dShadow);
    float ao = exp(-max(d, 0.0) * 1.4);
    float under = clamp(shadow * 0.72 + ao * 0.38, 0.0, 0.88);

    if (d < aa * 2.0) {
        // Ridge surface lit from a fake height field.
        float e = 0.35;
        float h = reefHeight(d, uv, u);
        float2 ux = uv + float2(e, 0) / u.wallRes, uy = uv + float2(0, e) / u.wallRes;
        float hx = reefHeight(reefField(field, ux, u), ux, u);
        float hy = reefHeight(reefField(field, uy, u), uy, u);
        float3 n = normalize(float3(-(hx - h) / e * 3.2, -(hy - h) / e * 3.2, 1.0));
        float diff = clamp(dot(n, L), 0.0, 1.0);
        float3 V = float3(0, 0, 1);
        float spec = pow(clamp(dot(reflect(-L, n), V), 0.0, 1.0), 18.0);

        float3 dark = float3(0.004, 0.007, 0.011);
        float3 lit = float3(0.050, 0.060, 0.066);
        float3 body = mix(dark, lit, diff * diff * 0.8 + diff * 0.2);
        // Mineral banding and colour drift across the ridge.
        float band = pfbm(uv, u.wallRes * 0.6, 3);
        body *= mix(float3(0.88, 0.96, 1.08), float3(1.14, 1.00, 0.86), smoothstep(0.35, 0.7, band));
        // Fine grain and dark crevices.
        float grain = pnoise(uv * u.wallRes * 6.0, u.wallRes * 6.0);
        body *= 0.88 + 0.24 * grain;
        float crev = smoothstep(0.08, 0.0, abs(pfbm(uv, u.wallRes * 0.9, 3) - 0.5));
        body *= 1.0 - 0.55 * crev * smoothstep(-0.3, -1.2, d);
        body *= 0.6 + 0.4 * smoothstep(0.0, 0.7, h);

        // Coral crust: rounded polyps of muted colour on the slopes and the outer rim.
        float crustZone = smoothstep(-1.5, -0.6, d) * smoothstep(0.2, -0.25, d);
        float lod = smoothstep(1.5, 5.0, pxPerCell * 0.5);
        if (crustZone > 0.0 && lod > 0.0) {
            float4 cv = pcells(uv * u.wallRes * 2.0, u.wallRes * 2.0);
            float caa = fwidth(cv.x) + 0.02;
            float blob = smoothstep(0.30 + caa, 0.30 - caa, cv.x);
            float3 c1 = float3(0.110, 0.022, 0.036);  // rose
            float3 c2 = float3(0.100, 0.050, 0.014);  // amber
            float3 c3 = float3(0.040, 0.020, 0.080);  // violet
            float3 c4 = float3(0.012, 0.060, 0.056);  // jade
            float3 coral = cv.y < 0.3 ? c1 : (cv.y < 0.55 ? c2 : (cv.y < 0.8 ? c3 : c4));
            // Each coral head is a small dome lit like the ridge.
            float2 q = cv.zw / 0.30;
            float3 dn = normalize(float3(q, sqrt(max(1.0 - dot(q, q), 0.0)) + 0.15));
            float cd = clamp(dot(dn, L), 0.0, 1.0);
            coral *= 0.25 + 1.3 * cd * cd;
            coral += float3(0.05, 0.05, 0.05) * pow(cd, 12.0);
            // Coral grows in colonies: patches along the rim, not everywhere.
            float colony = smoothstep(0.45, 0.65, pfbm(uv, u.wallRes * 0.5, 2));
            float present = step(0.35, ghash12(float2(cv.y * 91.0, 3.0))) * colony;
            body = mix(body, coral, blob * crustZone * present * lod);
        }

        // Caustic light rippling over the crest.
        float2 cq = world * 0.006 + float2(t * 0.02, -t * 0.015);
        float caus = pow(1.0 - abs(sin(cq.x * 3.0 + sin(cq.y * 2.3 + t * 0.4) * 1.4)), 6.0)
                   * pow(1.0 - abs(sin(cq.y * 2.6 + sin(cq.x * 1.9 - t * 0.35) * 1.3)), 4.0);
        body += float3(0.03, 0.07, 0.075) * caus * smoothstep(0.2, 0.9, h) * diff;
        body += float3(0.30, 0.38, 0.40) * spec * 0.18 * smoothstep(0.1, 0.6, h);

        // Bright lip where the ridge meets the water.
        float lip = smoothstep(-0.55, -0.05, d) * cover;
        body += float3(0.02, 0.06, 0.065) * lip * (0.4 + 0.6 * diff);

        rgb = body * cover;
        alpha = cover;
    }

    // Bioluminescent fringe: a soft glow plus tiny pulsing polyps along the outline.
    // Brighter when zoomed out so the coastline still reads.
    float fringe = exp(-abs(d + 0.1) * 4.5) * mix(1.8, 0.7, smoothstep(4.0, 24.0, pxPerCell));
    float3 glowCol = mix(float3(0.010, 0.060, 0.070), float3(0.050, 0.020, 0.070), pfbm(uv, u.wallRes * 0.25, 2));
    rgb += glowCol * fringe * (0.5 + 0.5 * (1.0 - cover));
    float polypLod = smoothstep(2.5, 7.0, pxPerCell * 0.33);
    if (polypLod > 0.0 && abs(d - 0.15) < 0.6) {
        float period = u.wallRes * 3.0;
        float2 g = uv * period;
        float2 cell = floor(g);
        float2 pc = ghash22(wrapCell(cell, period)) * 0.6 + 0.2;
        float id = ghash12(wrapCell(cell, period) + 5.3);
        float dd = length(fract(g) - pc);
        float colony = smoothstep(0.40, 0.62, pfbm(uv, u.wallRes * 0.5, 2));
        float pd = smoothstep(0.15, 0.0, dd) * step(0.62, id) * (0.25 + 0.75 * colony);
        float pulse = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * (1.2 + id * 2.0) + id * 40.0), 3.0);
        float3 pcol = id < 0.86 ? float3(0.25, 1.10, 0.95) : float3(1.00, 0.35, 0.85);
        rgb += pcol * pd * pulse * polypLod * smoothstep(0.6, 0.1, abs(d - 0.15)) * 0.8;
    }

    alpha = alpha + (1.0 - alpha) * under * (1.0 - cover);
    return float4(rgb, alpha);
}

// MARK: - Miasma around sick creatures

struct MiasmaOut {
    float4 position [[position]];
    float2 local;
    float seed;
};

vertex MiasmaOut miasmaVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant GodUniforms &u [[buffer(0)]],
                              const device CreatureInstance *cs [[buffer(1)]]) {
    CreatureInstance c = cs[iid];
    MiasmaOut o;
    bool sick = fmod(floor(c.flags / 16.0), 2.0) >= 1.0;
    bool egg = fmod(c.flags, 2.0) >= 1.0;
    o.local = float2(0);
    o.seed = 0;
    if (!sick || egg) {
        o.position = float4(-2.0, -2.0, 0.0, 1.0);   // degenerate: nothing drawn
        return o;
    }
    float r = max(c.radius, 0.5);
    float size = max(r * 4.2, 10.0 * u.pixelRatio / u.zoom);
    float2 corner = godQuad[vid] * 2.0 - 1.0;
    float2 dir = float2(cos(c.heading), sin(c.heading));
    float2 center = c.position + c.velocity * u.extrap - dir * r * 1.1;
    float2 world = center + corner * size;
    float2 px = (world + u.offset - u.camCenter) * u.zoom + u.viewSize * 0.5;
    float2 ndc = px / u.viewSize * 2.0 - 1.0;
    o.position = float4(ndc.x, -ndc.y, 0, 1);
    o.local = corner;
    o.seed = c.hue * 91.7 + c.swimPhase * 0.01 + float(iid) * 0.618;
    return o;
}

fragment float4 miasmaFragment(MiasmaOut in [[stage_in]], constant GodUniforms &u [[buffer(0)]]) {
    float d = length(in.local);
    if (d > 1.0) return float4(0);
    float t = u.time;
    float pulse = 0.7 + 0.3 * sin(t * 2.1 + in.seed * 7.0);
    float wisp = gnoise(in.local * 2.5 + float2(in.seed, t * 0.4));
    float haze = exp(-d * d * 3.5) * (0.6 + 0.6 * wisp) * pulse;
    float3 col = float3(0.050, 0.110, 0.008) * haze;
    // Spores drifting away from the body.
    for (int k = 0; k < 6; k++) {
        float fk = float(k);
        float ph = fract(t * 0.22 + fk / 6.0 + fract(in.seed * 0.37));
        float ang = fk * 2.399 + in.seed * 3.0 + ph * 0.9;
        float2 sp = float2(cos(ang), sin(ang)) * (0.18 + 0.72 * ph);
        float sr = 0.075 * (1.0 - 0.4 * ph);
        float s = smoothstep(sr, 0.0, length(in.local - sp));
        col += float3(0.50, 1.10, 0.10) * s * (1.0 - ph) * 0.8;
    }
    return float4(col, haze * 0.22);
}

// MARK: - Climate colour grade (programmable blending: reads the scene colour in place)

inline float ridged(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        float n = gnoise(p);
        v += a * pow(1.0 - abs(n * 2.0 - 1.0), 5.0);
        p = float2(p.x * 1.7 - p.y * 1.1, p.x * 1.1 + p.y * 1.7) + 3.1;
        a *= 0.55;
    }
    return v;
}

inline float motes(float2 sp, float scale, float2 drift, float seed, float radius) {
    float2 g = (sp + drift) / scale;
    float2 cell = floor(g);
    float2 pos = ghash22(cell + seed) * 0.8 + 0.1;
    float on = step(0.55, ghash12(cell + seed * 1.7));
    float r = radius / scale;
    return smoothstep(r, 0.0, length(fract(g) - pos)) * on;
}

fragment float4 gradeFragment(GodFSOut in [[stage_in]],
                              float4 dst [[color(0)]],
                              constant GodUniforms &u [[buffer(0)]]) {
    float3 col = dst.rgb;
    float t = u.time;
    float2 sp = in.uv * u.viewSize / u.pixelRatio;   // screen points
    float2 e2 = abs(in.uv - 0.5) * 2.0;
    float edge = pow(pow(e2.x, 4.0) + pow(e2.y, 4.0), 0.25);   // 0 centre .. 1 border (squircle)
    float lum = dot(col, float3(0.2126, 0.7152, 0.0722));

    if (u.ice > 0.001) {
        float ice = u.ice;
        // Cold, desaturated light with a milky haze.
        float3 cold = lum * float3(0.62, 0.90, 1.35);
        col = mix(col, cold, 0.62 * ice);
        col += float3(0.0035, 0.0080, 0.0140) * ice;
        // Frost creeping in from the frame.
        float n = gnoise(sp * 0.008) * 0.6 + gnoise(sp * 0.021) * 0.4;
        float reach = mix(1.05, 0.66, ice);
        float mask = smoothstep(reach, reach + 0.22, edge + (n - 0.5) * 0.45);
        float veins = ridged(sp * 0.018);
        float fine = ridged(sp * 0.06 + 7.0);
        float3 frost = float3(0.060, 0.095, 0.140) * (0.35 + 1.4 * veins + 0.6 * fine);
        col = mix(col, col * 0.35 + frost, mask * 0.9);
        // Glints in the frost.
        float2 gc = floor(sp / 7.0);
        float tw = pow(0.5 + 0.5 * sin(t * (2.0 + ghash12(gc) * 3.0) + ghash12(gc + 3.0) * 30.0), 12.0);
        float glint = step(0.93, ghash12(gc + 9.1)) * tw * smoothstep(0.35, 0.0, length(fract(sp / 7.0) - 0.5));
        col += float3(0.7, 0.85, 1.0) * glint * mask * 0.9;
        // Ice motes drifting through the water.
        float m = motes(sp, 64.0, float2(t * 7.0, t * 16.0), 1.0, 1.3) * 0.6
                + motes(sp, 140.0, float2(t * 12.0, t * 30.0), 7.0, 2.4);
        col += float3(0.20, 0.27, 0.34) * m * ice * 0.55;
    }

    if (u.warm > 0.001) {
        float warm = u.warm;
        float l2 = dot(col, float3(0.2126, 0.7152, 0.0722));
        col = max(mix(float3(l2), col, 1.0 + 0.30 * warm), 0.0);
        col *= mix(float3(1.0), float3(1.22, 1.04, 0.78), warm);
        col += float3(0.0060, 0.0036, 0.0008) * warm;
        // Sun shafts slanting from the upper left.
        float2 dir = normalize(float2(0.85, 0.52));
        float across = dot(sp, float2(-dir.y, dir.x));
        float rays = pow(gnoise(float2(across * 0.010, t * 0.06)), 2.5) * 0.7
                   + pow(gnoise(float2(across * 0.026 + 9.0, t * 0.09)), 3.0) * 0.5;
        float fall = smoothstep(1.5, 0.0, length(in.uv * float2(u.viewSize.x / u.viewSize.y, 1.0)));
        col += float3(0.050, 0.030, 0.008) * rays * fall * warm;
        // Warm glow at the frame and drifting pollen.
        col += float3(0.012, 0.005, 0.0) * smoothstep(0.5, 1.1, edge) * warm;
        float m = motes(sp, 80.0, float2(t * 4.0, -t * 9.0), 3.0, 1.4) * 0.7
                + motes(sp, 150.0, float2(-t * 6.0, -t * 15.0), 11.0, 2.2);
        col += float3(0.40, 0.26, 0.06) * m * warm * 0.45;
    }
    return float4(col, dst.a);
}
"""#
