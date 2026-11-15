// Metal shader source, compiled at runtime (SwiftPM command-line builds do not process .metal files).

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types (layouts must match Swift)

struct Uniforms {
    float2 viewSize;     // drawable size in pixels
    float2 camCenter;    // world position at the centre of the view
    float2 worldSize;
    float2 hoverPos;     // world position of the tool cursor
    float2 offset;       // torus offset for this draw call
    float zoom;          // pixels per world unit
    float time;          // seconds, wall clock
    float extrap;        // world seconds to extrapolate positions by
    float pixelRatio;    // backing scale factor
    float season;
    float selected;      // instance index of the selected creature or -1
    float hoverRadius;
    float toolKind;
    float bloomStrength;
    float exposure;
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
    float flags;         // integer bits; the fractional part fades the creature out (time-lapse)
    float maturity;
    float signal;
};

struct FoodInstance {
    float2 position;
    float energy;
    float kind;
};

struct Particle {
    float2 position;
    float size;      // world units
    float life;      // 1 -> 0
    float4 color;    // rgb (HDR), a = shape (0 dot, 1 ring, 2 spark)
};

struct Ring {
    float2 position;
    float radius;    // world units
    float thickness; // pixels
    float4 color;
    float dash;      // 0 solid, >0 dash count
    float spin;
    float2 pad;
};

// MARK: - Helpers

constant float2 quadCorners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

inline float4 worldToClip(float2 world, constant Uniforms &u) {
    float2 d = world + u.offset - u.camCenter;
    float2 px = d * u.zoom + u.viewSize * 0.5;
    float2 ndc = px / u.viewSize * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0, 1);
}

inline float3 hsv2rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

inline float3 srgbToLinear(float3 c) { return pow(max(c, 0.0), 2.2); }

inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

inline float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

inline float sdSegment(float2 p, float2 a, float2 b, float ra, float rb) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - mix(ra, rb, h);
}

inline float sdEllipse(float2 p, float2 r) {
    // Cheap approximation, good enough for soft fins.
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-4);
}

// MARK: - Background

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

inline float caustic(float2 p, float t) {
    // Domain-warped ridges: bright thin filaments like light refracted by ripples.
    float2 q = p;
    float v = 0.0;
    for (int n = 0; n < 3; n++) {
        float fn = float(n);
        q = float2(q.x + sin(q.y * 1.3 + t * (0.7 + fn * 0.2)) * 0.55,
                   q.y + sin(q.x * 1.1 - t * (0.6 + fn * 0.15)) * 0.55);
        v += abs(sin(q.x * 1.9 + q.y * 1.6 + fn));
    }
    v = clamp(1.0 - v / 3.0, 0.0, 1.0);
    return pow(v, 5.0);
}

fragment float4 backgroundFragment(FullscreenOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> fertility [[texture(0)]]) {
    constexpr sampler s(address::repeat, filter::linear);
    float2 px = in.uv * u.viewSize;
    float2 world = u.camCenter + (px - u.viewSize * 0.5) / u.zoom;
    float2 wuv = world / u.worldSize;
    float f = fertility.sample(s, wuv).r;
    float t = u.time;

    float3 abyss = float3(0.0020, 0.0050, 0.0140);
    float3 lagoon = float3(0.0040, 0.0260, 0.0340);
    float3 bloomTint = float3(0.0080, 0.0400, 0.0240);
    float3 col = mix(abyss, lagoon, smoothstep(0.02, 0.55, f));
    col = mix(col, bloomTint, smoothstep(0.45, 0.95, f) * 0.6);

    // Silt texture in world space (fades as we zoom out).
    float detail = clamp(u.zoom * 0.6, 0.0, 1.0);
    float silt = noise2(world * 0.05) * 0.6 + noise2(world * 0.17) * 0.4;
    col *= 1.0 + (silt - 0.5) * 0.35 * detail;

    // Drifting caustic light.
    float c = caustic(world * 0.0045 + float2(t * 0.01, -t * 0.007), t * 0.35);
    col += float3(0.020, 0.055, 0.065) * c * (0.45 + 0.75 * f) * (0.7 + 0.3 * u.season);
    // Broad, slowly drifting light pools.
    float pools = noise2(world * 0.0012 + float2(t * 0.004, -t * 0.003));
    col *= 0.75 + 0.6 * pools;

    // Faint floating plankton specks.
    float2 g = world * 0.03 + float2(t * 0.05, t * 0.02);
    float2 cell = floor(g);
    float2 r = hash22(cell) * 0.7 + 0.15;
    float speck = smoothstep(0.08, 0.0, length(fract(g) - r)) * step(0.82, hash12(cell + 7.0));
    col += float3(0.05, 0.09, 0.10) * speck * detail * 0.5;

    return float4(col, 1.0);
}

// MARK: - Food

struct FoodOut {
    float4 position [[position]];
    float2 local;
    float kind;
    float intensity;
    float seed;
};

vertex FoodOut foodVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Uniforms &u [[buffer(0)]],
                          const device FoodInstance *food [[buffer(1)]]) {
    FoodInstance f = food[iid];
    float base = (f.kind < 0.5) ? (0.9 + 0.8 * sqrt(max(f.energy, 0.0) / 40.0))
                                : (1.1 + 0.9 * sqrt(max(f.energy, 0.0) / 60.0));
    float px = base * u.zoom;
    float minPx = 1.4 * u.pixelRatio;
    float scale = max(px, minPx) / max(px, 1e-4);
    float sizeW = base * scale * 3.2;
    float2 c = quadCorners[vid] * 2.0 - 1.0;
    FoodOut o;
    o.position = worldToClip(f.position + c * sizeW, u);
    o.local = c * 3.2;
    o.kind = f.kind;
    // Keep total brightness roughly constant when clamped to a minimum pixel size.
    o.intensity = min(1.0, (px * px) / (minPx * minPx) + 0.25);
    o.seed = hash12(f.position);
    return o;
}

fragment float4 foodFragment(FoodOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = in.local;
    float d = length(p);
    float ang = atan2(p.y, p.x);
    float3 col;
    float alpha;
    if (in.kind < 0.5) {
        // Algae: a tiny lobed body with a soft green glow.
        float lobes = 1.0 + 0.16 * cos(ang * 3.0 + in.seed * 6.28) + 0.08 * cos(ang * 5.0 - in.seed * 3.0);
        float body = d - 0.85 * lobes;
        float aa = fwidth(body) + 1e-3;
        float core = 1.0 - smoothstep(-aa, aa, body);
        float pulse = 0.8 + 0.2 * sin(u.time * 1.3 + in.seed * 20.0);
        float3 green = mix(float3(0.05, 0.75, 0.42), float3(0.42, 0.95, 0.18), in.seed);
        green = mix(green, float3(0.1, 0.8, 0.75), step(0.85, fract(in.seed * 7.3)) * 0.7);
        float inner = smoothstep(0.85, 0.0, d);
        col = green * (0.35 + 0.75 * inner) * core * 0.95 * pulse;
        col += green * exp(-d * d * 1.4) * 0.09 * pulse;
        alpha = core * 0.55;
    } else {
        // Meat: jagged chunk, warm glow.
        float jag = 1.0 + 0.22 * noise2(float2(ang * 2.2, in.seed * 13.0)) - 0.11;
        float body = d - 0.9 * jag;
        float aa = fwidth(body) + 1e-3;
        float core = 1.0 - smoothstep(-aa, aa, body);
        float3 red = float3(1.0, 0.22, 0.08);
        col = red * (0.5 + 0.8 * smoothstep(0.9, 0.0, d)) * core * 1.2;
        col += float3(1.0, 0.35, 0.1) * exp(-d * d * 1.2) * 0.18;
        alpha = core * 0.7;
    }
    col *= in.intensity;
    return float4(col, alpha * in.intensity);
}

// MARK: - Creatures

struct CreatureOut {
    float4 position [[position]];
    float2 local;            // body units (1 = body radius)
    float pxPerUnit;
    uint iid [[flat]];
};

constant float kHeadX = 0.45;

inline int segmentCount(float g) { return 2 + int(min(g * 5.0, 4.0)); }
inline float segSpacing(float diet) { return mix(0.82, 0.95, diet); }
inline float bodyLength(CreatureInstance c) { return float(segmentCount(c.segments) - 1) * segSpacing(c.diet); }
inline float tailLength(CreatureInstance c) { return 0.6 + c.tail * 2.4; }

vertex CreatureOut creatureVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  constant Uniforms &u [[buffer(0)]],
                                  const device CreatureInstance *cs [[buffer(1)]]) {
    CreatureInstance c = cs[iid];
    bool egg = fmod(c.flags, 2.0) >= 1.0;
    float r = max(c.radius, 0.5);
    float pxPerUnit = r * u.zoom;
    // Keep tiny creatures visible as glowing dots.
    float minPx = 1.6 * u.pixelRatio;
    float vis = max(pxPerUnit, minPx) / pxPerUnit;
    float2 lo, hi;
    if (egg) {
        lo = float2(-2.2); hi = float2(2.2);
    } else {
        float back = bodyLength(c) + tailLength(c) + 1.4;
        float side = 1.9 + c.fins * 1.1;
        lo = float2(-back, -side);
        hi = float2(2.4, side);
    }
    // Room for the glow halo.
    lo -= 0.8; hi += 0.8;
    float2 local = mix(lo, hi, quadCorners[vid]);
    float h = c.heading;
    float2 dir = float2(cos(h), sin(h));
    float2 nrm = float2(-dir.y, dir.x);
    float2 center = c.position + c.velocity * u.extrap;
    float2 world = center + (dir * local.x + nrm * local.y) * r * vis;
    CreatureOut o;
    o.position = worldToClip(world, u);
    o.local = local;
    o.pxPerUnit = pxPerUnit * vis;
    o.iid = iid;
    return o;
}

struct BodySample {
    float d;          // signed distance of the body (units)
    float fin;        // signed distance of fins and tail fan
    float jaw;        // signed distance of mandibles
    float3 normal;    // fake 3D normal for shading
    float along;      // 0 head .. 1 tail end, for patterns
    float spineY;
};

inline BodySample sampleBody(float2 p, CreatureInstance c, float t) {
    BodySample b;
    int n = segmentCount(c.segments);
    float sp = segSpacing(c.diet);
    float phase = c.swimPhase;
    float amp = 0.10 + 0.06 * c.tail;
    float roundness = mix(1.08, 0.86, c.diet);
    float d = 1e5;
    float bestSeg = 1e5;
    float2 bestC = float2(0);
    float bestR = 1.0;
    float lastX = kHeadX, lastY = 0, lastR = 1;
    for (int k = 0; k < 6; k++) {
        if (k >= n) break;
        float fk = float(k);
        float x = kHeadX - fk * sp;
        float y = sin(phase - fk * 0.95) * amp * fk;
        float r = (k == 0 ? 0.80 : (1.0 - 0.13 * (fk - 1.0))) * roundness;
        if (k == 0) r *= mix(1.0, 0.92, c.diet);
        float2 cc = float2(x, y);
        float ds = length(p - cc) - r;
        d = (k == 0) ? ds : smin(d, ds, 0.22);
        if (ds < bestSeg) { bestSeg = ds; bestC = cc; bestR = r; }
        lastX = x; lastY = y; lastR = r;
    }
    // Carnivores grow dorsal spikes; herbivores have soft cilia.
    float2 q = p - bestC;
    float theta = atan2(q.y, q.x);
    float spikes = smoothstep(0.42, 0.9, c.diet);
    d -= spikes * 0.17 * pow(max(0.0, sin(theta * 7.0 + bestC.x * 3.0)), 6.0) * smoothstep(-0.3, 0.2, -q.x * 0.0 + 1.0);
    d -= smoothstep(0.3, 0.0, c.diet) * 0.018 * sin(theta * 22.0 + t * 6.0 + bestC.x * 9.0);

    // Tail stalk + fan.
    float T = tailLength(c);
    float tx0 = lastX - lastR * 0.55;
    float tt = clamp((tx0 - p.x) / T, 0.0, 1.0);
    float tailAmp = amp * 1.2;
    float tailPhase = phase - float(n) * 0.95;
    float bend = lastY + sin(tailPhase - tt * 2.2) * tailAmp * (1.0 + tt * 3.0);
    float2 prev = float2(tx0, lastY);
    float prevR = 0.30 * lastR + 0.05;
    for (int m = 1; m <= 4; m++) {
        float tm = float(m) / 4.0;
        float2 pt = float2(tx0 - T * tm, lastY + sin(tailPhase - tm * 2.2) * tailAmp * (1.0 + tm * 3.0));
        float rm = mix(0.30 * lastR + 0.05, 0.04, tm);
        d = smin(d, sdSegment(p, prev, pt, prevR, rm), 0.1);
        prev = pt; prevR = rm;
    }
    float fanStart = 0.45;
    float fanT = smoothstep(fanStart, 1.0, tt);
    float fanW = (0.2 + 0.9 * c.tail) * fanT * (1.0 - 0.35 * smoothstep(0.92, 1.0, tt));
    float fork = 0.25 * c.diet * fanT;
    float fan = abs(abs(p.y - bend) - fork) - fanW;
    fan = max(fan, abs(tx0 - p.x - T * 0.5) - T * 0.5 - 0.05);
    float finD = fan;

    // Side fins on the second segment, flapping.
    if (c.fins > 0.05) {
        float x1 = kHeadX - sp * 1.0;
        float y1 = sin(phase - 0.95) * amp;
        float flap = sin(phase * 1.3) * 0.35;
        for (int s = -1; s <= 1; s += 2) {
            float fs = float(s);
            float2 anchor = float2(x1 + 0.05, y1 + fs * 0.75 * roundness);
            float a = -0.6 + flap * fs * 0.0 - flap;
            float2 lp = p - anchor;
            float ca = cos(a * fs), sa = sin(a * fs);
            lp = float2(ca * lp.x + sa * lp.y, -sa * lp.x + ca * lp.y);
            float2 size = float2(0.35 + 0.75 * c.fins, 0.16 + 0.2 * c.fins);
            float e = sdEllipse(lp - float2(-size.x * 0.55, fs * size.y * 0.9), size);
            finD = min(finD, e);
        }
    }

    // Mandibles for predators.
    float jaw = 1e5;
    if (c.diet > 0.5) {
        bool biting = fmod(floor(c.flags / 2.0), 2.0) >= 1.0;
        float open = biting ? (0.5 + 0.5 * sin(t * 22.0)) : 0.25;
        float jl = 0.35 + 0.55 * smoothstep(0.5, 1.0, c.diet);
        for (int s = -1; s <= 1; s += 2) {
            float fs = float(s);
            float2 a0 = float2(kHeadX + 0.6, fs * 0.38);
            float2 a1 = float2(kHeadX + 0.6 + jl, fs * (0.08 + open * 0.32));
            float2 mid = (a0 + a1) * 0.5 + float2(0.0, fs * 0.16);
            float j = min(sdSegment(p, a0, mid, 0.13, 0.08), sdSegment(p, mid, a1, 0.08, 0.015));
            jaw = min(jaw, j);
        }
    }

    b.d = d;
    b.fin = finD;
    b.jaw = jaw;
    float2 nq = (p - bestC) / bestR;
    float z = sqrt(max(0.0, 1.0 - dot(nq, nq)));
    b.normal = normalize(float3(nq * 0.9, z + 0.25));
    b.along = clamp((kHeadX + 1.0 - p.x) / (float(n) * sp + T + 1.0), 0.0, 1.0);
    b.spineY = bestC.y;
    return b;
}

fragment float4 creatureFragment(CreatureOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 const device CreatureInstance *cs [[buffer(1)]]) {
    CreatureInstance c = cs[in.iid];
    float2 p = in.local;
    float t = u.time;
    bool egg = fmod(c.flags, 2.0) >= 1.0;
    bool eating = fmod(floor(c.flags / 4.0), 2.0) >= 1.0;
    float energy = clamp(c.energy, 0.0, 1.0);
    float sat = clamp(c.saturation * 0.85 + 0.1, 0.0, 1.0);
    float3 base = srgbToLinear(hsv2rgb(c.hue, sat, 0.95));
    float3 deep = srgbToLinear(hsv2rgb(c.hue + 0.04, min(1.0, sat + 0.15), 0.30));
    float hurt = c.hurt * (0.6 + 0.4 * sin(t * 30.0));
    float glowAmt = 0.35 + 1.1 * energy;
    // Illness (flag 16): sallow yellow-green colouring and a weak, flickering glow.
    bool sick = fmod(floor(c.flags / 16.0), 2.0) >= 1.0;
    if (sick) {
        float l = max(dot(base, float3(0.3, 0.5, 0.2)), 0.18);
        base = mix(base, float3(0.20, 0.62, 0.10) * l * 1.3, 0.85);
        deep = mix(deep, float3(0.035, 0.05, 0.0), 0.7);
        glowAmt *= 0.5 + 0.3 * sin(t * 3.7 + c.hue * 30.0);
    }
    float vis = 1.0 - fract(c.flags);

    // LOD: far away creatures are luminous dots.
    float lod = smoothstep(2.0, 5.0, in.pxPerUnit);

    if (egg) {
        // Jelly egg: translucent tinted capsule with a curled embryo and a beating glow.
        float d = length(p) - 1.25;
        float aa = fwidth(d) + 1e-3;
        float cover = 1.0 - smoothstep(-aa, aa, d);
        float inside = clamp(-d / 1.25, 0.0, 1.0);
        float beat = 0.55 + 0.45 * pow(max(0.0, sin(t * 3.0 + c.hue * 40.0)), 6.0);
        float wob = sin(t * 1.6 + c.hue * 20.0) * 0.08;
        // Curled embryo: head plus a tapering tail wrapped around it.
        float2 hc = float2(cos(-0.3 + wob), sin(-0.3 + wob)) * 0.32;
        float emb = length(p - hc) - 0.36;
        for (int k = 1; k <= 5; k++) {
            float a = -0.3 + wob + float(k) * 0.62;
            float2 q = float2(cos(a), sin(a)) * (0.36 - float(k) * 0.025);
            emb = smin(emb, length(p - q) - (0.30 - float(k) * 0.045), 0.12);
        }
        float ecov = 1.0 - smoothstep(-aa, aa, emb);
        float2 eyeP = hc + float2(cos(-0.3 + wob + 0.5), sin(-0.3 + wob + 0.5)) * 0.14;
        float eye = 1.0 - smoothstep(0.07, 0.07 + aa, length(p - eyeP));
        float3 jelly = mix(float3(0.10, 0.16, 0.20), base * 0.35, 0.6);
        float3 col = jelly * cover * (0.25 + 0.5 * (1.0 - inside));
        float rim = smoothstep(0.10, 0.0, abs(d + 0.05)) * cover;
        col += (base * 0.7 + float3(0.25)) * rim * 0.9;
        col = mix(col, base * (0.9 + 0.9 * beat), ecov);
        col = mix(col, float3(0.02), eye * ecov);
        float spec = smoothstep(0.28, 0.0, length(p - float2(0.48, -0.55)));
        col += float3(1.0) * spec * 0.65 * cover;
        col += base * exp(-max(d, 0.0) * 3.5) * 0.18 * beat * (1.0 - cover);
        float alpha = cover * (0.30 + 0.55 * ecov + 0.3 * rim);
        return float4(col, alpha) * vis;
    }

    float3 color = float3(0);
    float alpha = 0;

    if (lod < 1.0) {
        float dd = length(p - float2(-bodyLength(c) * 0.4, 0.0)) - 1.0 - bodyLength(c) * 0.3;
        float core = smoothstep(1.2, -0.6, dd);
        float3 dot = base * (0.6 + 1.2 * energy) * core * 1.6 + base * exp(-max(dd, 0.0) * 1.2) * 0.25;
        dot = mix(dot, float3(1.6, 0.1, 0.05), hurt * 0.7);
        color = dot * (1.0 - lod);
        alpha = core * 0.8 * (1.0 - lod);
        if (lod <= 0.0) return float4(color, alpha) * vis;
    }

    BodySample b = sampleBody(p, c, t);
    float aa = max(fwidth(b.d), 1e-3) * 1.2;
    float cover = 1.0 - smoothstep(-aa, aa, b.d);
    float finAA = max(fwidth(b.fin), 1e-3) * 1.2;
    float finCover = (1.0 - smoothstep(-finAA, finAA, b.fin)) * (1.0 - cover);
    float jawAA = max(fwidth(b.jaw), 1e-3) * 1.2;
    float jawCover = (1.0 - smoothstep(-jawAA, jawAA, b.jaw));

    // Membrane shading: translucent interior, bright rim, fake sphere lighting.
    float depth = clamp(-b.d / 0.55, 0.0, 1.0);
    float3 L = normalize(float3(-0.45, -0.55, 0.75));
    float diff = clamp(dot(b.normal, L), 0.0, 1.0);
    float spec = pow(clamp(dot(reflect(-L, b.normal), float3(0, 0, 1)), 0.0, 1.0), 24.0);
    float3 body = mix(base * 1.25, deep, smoothstep(0.0, 1.0, depth) * 0.55);
    body *= 0.35 + 0.85 * diff;

    // Patterns.
    float pat = c.pattern;
    float along = b.along;
    if (pat < 0.33) {
        float stripes = smoothstep(0.15, 0.0, abs(fract(p.x * 1.55 + 0.25) - 0.5) - 0.18);
        body = mix(body, deep * 0.6, stripes * 0.55 * smoothstep(0.05, 0.25, depth));
    } else if (pat < 0.66) {
        float2 g = p * 3.2 + float2(c.hue * 37.0, 0.0);
        float2 cell = floor(g);
        float2 r = hash22(cell) * 0.6 + 0.2;
        float spot = smoothstep(0.24, 0.12, length(fract(g) - r)) * step(0.35, hash12(cell + 3.1));
        // Bioluminescent photophores.
        body += base * spot * (0.8 + 1.4 * energy) * smoothstep(0.05, 0.3, depth) * (0.7 + 0.3 * sin(t * 2.0 + cell.x));
    } else {
        float band = smoothstep(0.22, 0.05, abs(p.y - b.spineY));
        body = mix(body, base * 1.8, band * 0.45 * smoothstep(0.05, 0.25, depth));
        body = mix(body, deep * 0.7, smoothstep(0.4, 0.9, abs(p.y - b.spineY)) * 0.35);
    }

    // Rim light and specular sheen.
    float rim = smoothstep(0.22, 0.0, -b.d) * cover;
    body += base * rim * 1.2 * glowAmt;
    body += float3(1.0) * spec * 0.55 * cover;

    // Starving creatures fade toward grey.
    float starving = smoothstep(0.25, 0.0, energy);
    body = mix(body, float3(dot(body, float3(0.3, 0.5, 0.2))) * 0.6, starving * 0.7);
    body = mix(body, float3(1.8, 0.12, 0.06), hurt * 0.65);
    if (sick) {
        // Dark lesions and pale pustules.
        float lesion = smoothstep(0.58, 0.72, noise2(p * 2.8 + c.hue * 53.0));
        body = mix(body, float3(0.05, 0.06, 0.0), lesion * 0.75 * cover);
        float pus = smoothstep(0.80, 0.86, noise2(p * 6.0 - c.hue * 17.0));
        body += float3(0.55, 0.75, 0.10) * pus * (0.6 + 0.4 * sin(t * 5.0 + p.x * 3.0));
    }

    // Eyes.
    float eyeR = 0.15 + 0.2 * c.eyes;
    float eyeY = mix(0.52, 0.30, c.diet);
    float eyeX = kHeadX + 0.32;
    float3 eyeCol = float3(0);
    float eyeCover = 0;
    for (int s = -1; s <= 1; s += 2) {
        float2 ec = float2(eyeX, float(s) * eyeY);
        float de = length(p - ec) - eyeR;
        float ea = max(fwidth(de), 1e-3);
        float ecov = 1.0 - smoothstep(-ea, ea, de);
        float2 look = float2(0.35, 0.0) * eyeR;
        float dp = length(p - ec - look) - eyeR * 0.55;
        float pcov = 1.0 - smoothstep(-ea, ea, dp);
        float glint = smoothstep(eyeR * 0.28, 0.0, length(p - ec - float2(-0.2, -0.35) * eyeR));
        float3 ecolor = mix(float3(0.95, 0.97, 1.0) * 1.1, float3(0.01, 0.01, 0.02), pcov);
        ecolor += float3(1.0) * glint * 1.5;
        eyeCol = mix(eyeCol, ecolor, ecov);
        eyeCover = max(eyeCover, ecov);
    }
    body = mix(body, eyeCol, eyeCover * cover);

    // Mouth glow when eating.
    if (eating) {
        float m = smoothstep(0.35, 0.0, length(p - float2(kHeadX + 0.85, 0.0)));
        body += float3(0.4, 1.2, 0.5) * m * (0.5 + 0.5 * sin(t * 18.0));
    }

    // Fins: translucent and ribbed.
    float rib = 0.6 + 0.4 * sin(atan2(p.y, p.x + 1.0) * 40.0);
    float3 finCol = base * (0.35 + 0.5 * rib) * glowAmt;

    // Jaws.
    float3 jawCol = mix(deep * 1.4, float3(1.0, 0.85, 0.75), 0.35) + float3(0.6, 0.05, 0.02) * hurt;

    // Soft halo outside the body, energy-dependent.
    float outside = max(min(b.d, b.fin + 0.2), 0.0);
    float halo = exp(-outside * 3.2) * 0.22 * glowAmt;
    // Signalling creatures pulse a visible ring.
    float sig = smoothstep(0.55, 1.0, c.signal) * 0.35;
    float ringR = 1.2 + fract(t * 1.2) * 1.2;
    float sring = smoothstep(0.06, 0.0, abs(length(p - float2(-bodyLength(c) * 0.4, 0.0)) - ringR)) * sig * (1.0 - fract(t * 1.2));

    float3 col = float3(0);
    col += finCol * finCover * 0.8;
    col = mix(col, body, cover);
    col = mix(col, jawCol, jawCover * (1.0 - cover * 0.6));
    col += base * halo * (1.0 - cover);
    col += base * sring * 0.9;
    float a = max(cover, max(finCover * 0.55, jawCover));
    float4 detailed = float4(col * lod, a * lod);
    return float4(color + detailed.rgb, max(alpha, detailed.a)) * vis;
}

// MARK: - Particles

struct ParticleOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float life;
};

vertex ParticleOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  constant Uniforms &u [[buffer(0)]],
                                  const device Particle *ps [[buffer(1)]]) {
    Particle pt = ps[iid];
    float2 c = quadCorners[vid] * 2.0 - 1.0;
    float px = pt.size * u.zoom;
    float minPx = 1.5 * u.pixelRatio;
    float s = max(px, minPx) / max(px, 1e-4);
    ParticleOut o;
    o.position = worldToClip(pt.position + c * pt.size * s, u);
    o.local = c;
    o.color = pt.color;
    o.life = pt.life;
    return o;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]]) {
    float d = length(in.local);
    float shape = in.color.a;
    float window = clamp(1.0 - d * d, 0.0, 1.0);
    window *= window;
    float v;
    if (shape < 0.5) {
        v = exp(-d * d * 5.0);
    } else if (shape < 1.5) {
        float aa = fwidth(d) * 1.5 + 0.01;
        float w = 0.025 + 0.05 * in.life;
        v = smoothstep(w + aa, w - aa, abs(d - 0.85)) + exp(-pow(d - 0.85, 2.0) * 60.0) * 0.5;
    } else {
        v = exp(-d * d * 14.0) * 1.5;
    }
    float fade = in.life * in.life;
    return float4(in.color.rgb * v * fade * window, 0.0);
}

// MARK: - Rings (selection, tool cursor)

struct RingOut {
    float4 position [[position]];
    float2 local;
    float pxRadius;
    uint iid [[flat]];
};

vertex RingOut ringVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Uniforms &u [[buffer(0)]],
                          const device Ring *rings [[buffer(1)]]) {
    Ring r = rings[iid];
    float2 c = quadCorners[vid] * 2.0 - 1.0;
    float pxR = r.radius * u.zoom;
    float extent = (pxR + r.thickness * 3.0 + 4.0) / u.zoom;
    RingOut o;
    o.position = worldToClip(r.position + c * extent, u);
    o.local = c * extent * u.zoom;   // pixels
    o.pxRadius = pxR;
    o.iid = iid;
    return o;
}

fragment float4 ringFragment(RingOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                             const device Ring *rings [[buffer(1)]]) {
    Ring r = rings[in.iid];
    float d = length(in.local);
    float w = r.thickness * 0.5;
    float band = smoothstep(w + 1.0, w - 1.0, abs(d - in.pxRadius));
    float glow = exp(-pow((d - in.pxRadius) / (r.thickness * 3.0), 2.0)) * 0.35;
    if (r.dash > 0.0) {
        float a = atan2(in.local.y, in.local.x) + u.time * r.spin;
        float m = smoothstep(-0.15, 0.15, sin(a * r.dash));
        band *= m;
    }
    float v = band + glow;
    return float4(r.color.rgb * v, band * r.color.a * 0.5);
}

// MARK: - Bloom and composite

fragment float4 bloomDownsample(FullscreenOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant float4 &params [[buffer(0)]]) {
    // params: x = texel size x, y = texel size y, z = 1 for the first (prefilter) pass, w = threshold
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float2 ts = params.xy;
    float3 a = src.sample(s, uv + ts * float2(-2, -2)).rgb;
    float3 b = src.sample(s, uv + ts * float2( 0, -2)).rgb;
    float3 c = src.sample(s, uv + ts * float2( 2, -2)).rgb;
    float3 d = src.sample(s, uv + ts * float2(-2,  0)).rgb;
    float3 e = src.sample(s, uv).rgb;
    float3 f = src.sample(s, uv + ts * float2( 2,  0)).rgb;
    float3 g = src.sample(s, uv + ts * float2(-2,  2)).rgb;
    float3 h = src.sample(s, uv + ts * float2( 0,  2)).rgb;
    float3 i = src.sample(s, uv + ts * float2( 2,  2)).rgb;
    float3 j = src.sample(s, uv + ts * float2(-1, -1)).rgb;
    float3 k = src.sample(s, uv + ts * float2( 1, -1)).rgb;
    float3 l = src.sample(s, uv + ts * float2(-1,  1)).rgb;
    float3 m = src.sample(s, uv + ts * float2( 1,  1)).rgb;
    float3 col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    col = select(col, float3(0), isnan(col) || isinf(col));
    if (params.z > 0.5) {
        float br = max(col.r, max(col.g, col.b));
        float knee = params.w * 0.5;
        float soft = clamp(br - params.w + knee, 0.0, 2.0 * knee);
        soft = soft * soft / (4.0 * knee + 1e-4);
        float contrib = max(soft, br - params.w) / max(br, 1e-4);
        col *= contrib;
        col = min(col, float3(40.0));
    }
    return float4(col, 1.0);
}

fragment float4 bloomUpsample(FullscreenOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float2 ts = params.xy * 1.0;
    float3 col = src.sample(s, uv).rgb * 4.0;
    col += (src.sample(s, uv + ts * float2(-1, 0)).rgb + src.sample(s, uv + ts * float2(1, 0)).rgb +
            src.sample(s, uv + ts * float2(0, -1)).rgb + src.sample(s, uv + ts * float2(0, 1)).rgb) * 2.0;
    col += src.sample(s, uv + ts * float2(-1, -1)).rgb + src.sample(s, uv + ts * float2(1, -1)).rgb +
           src.sample(s, uv + ts * float2(-1, 1)).rgb + src.sample(s, uv + ts * float2(1, 1)).rgb;
    return float4(col / 16.0 * params.z, 1.0);
}

inline float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> hdr [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float3 col = hdr.sample(s, uv).rgb;
    float3 bl = bloom.sample(s, uv).rgb;
    col = select(col, float3(0), isnan(col) || isinf(col));
    bl = select(bl, float3(0), isnan(bl) || isinf(bl));
    col += bl * u.bloomStrength;
    col *= u.exposure;
    col = aces(col);
    // Vignette.
    float2 q = uv - 0.5;
    q.x *= u.viewSize.x / u.viewSize.y;
    float vig = smoothstep(1.05, 0.25, length(q));
    col *= mix(0.55, 1.0, vig);
    // Subtle film grain to avoid banding in the dark gradients.
    float grain = hash12(uv * u.viewSize + fract(u.time) * 917.0) - 0.5;
    col += grain * 0.012;
    return float4(col, 1.0);
}
"""#
