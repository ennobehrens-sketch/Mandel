// Metal source, compiled at runtime because `swift build` does not compile .metal files.
// It is compiled twice: with MANDEL_DF=0 (plain float, fast-math) and MANDEL_DF=1
// (double-float emulation, strict IEEE math so the error terms survive).
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

#ifndef MANDEL_DF
#define MANDEL_DF 0
#endif

// Must match `Uniforms` in Renderer.swift field for field (all 4-byte scalars, no padding).
struct Uniforms {
    float cxHi;
    float cxLo;
    float cyHi;
    float cyLo;
    float scaleHi;
    float scaleLo;
    float width;
    float height;
    uint  maxIter;
    uint  colorMode;    // 0 = smooth, 1 = banded
    uint  palette;
    float colorDensity;
};

struct VertexOut {
    float4 position [[position]];
};

// One triangle that covers the whole viewport.
vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    float2 uv = float2(float((vid << 1) & 2u), float(vid & 2u));
    VertexOut out;
    out.position = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
    return out;
}

constant float kEscape2 = 65536.0f;   // escape radius 256, large for smooth colouring

struct Orbit {
    bool  inside;
    float n;
    float r2;
};

static Orbit inside_orbit() {
    Orbit o;
    o.inside = true;
    o.n = 0.0f;
    o.r2 = 0.0f;
    return o;
}

static Orbit escaped_orbit(uint i, float r2) {
    Orbit o;
    o.inside = false;
    o.n = float(i + 1u);
    o.r2 = r2;
    return o;
}

// Main cardioid and period-2 bulb. The margin keeps float rounding from
// misclassifying escaping points close to the boundary at deep zoom.
static bool in_main_bulbs(float x, float y) {
    float y2 = y * y;
    float xq = x - 0.25f;
    float q = xq * xq + y2;
    if (q * (q + xq) < 0.25f * y2 - 1e-5f) return true;
    float xb = x + 1.0f;
    return xb * xb + y2 < 0.0625f - 1e-5f;
}

#if MANDEL_DF

// ---- double-float arithmetic: value = hi + lo, ~48-bit mantissa ----

static inline float2 quick_two_sum(float a, float b) {
    float s = a + b;
    float e = b - (s - a);
    return float2(s, e);
}

static inline float2 two_sum(float a, float b) {
    float s = a + b;
    float bb = s - a;
    float e = (a - (s - bb)) + (b - bb);
    return float2(s, e);
}

static inline float2 df_add(float2 a, float2 b) {
    float2 s = two_sum(a.x, b.x);
    float2 t = two_sum(a.y, b.y);
    s.y += t.x;
    s = quick_two_sum(s.x, s.y);
    s.y += t.y;
    return quick_two_sum(s.x, s.y);
}

static inline float2 df_sub(float2 a, float2 b) {
    return df_add(a, -b);
}

static inline float2 df_mul(float2 a, float2 b) {
    float p = a.x * b.x;
    float e = fma(a.x, b.x, -p);
    e = fma(a.x, b.y, e);
    e = fma(a.y, b.x, e);
    return quick_two_sum(p, e);
}

static inline float2 df_mul_f(float2 a, float b) {
    float p = a.x * b;
    float e = fma(a.x, b, -p);
    e = fma(a.y, b, e);
    return quick_two_sum(p, e);
}

static inline float2 df_sqr(float2 a) {
    float p = a.x * a.x;
    float e = fma(a.x, a.x, -p);
    e = fma(2.0f * a.x, a.y, e);
    return quick_two_sum(p, e);
}

static Orbit iterate(float px, float py, constant Uniforms& u) {
    float2 scale = float2(u.scaleHi, u.scaleLo);
    float2 cx = df_add(float2(u.cxHi, u.cxLo), df_mul_f(scale, px));
    float2 cy = df_add(float2(u.cyHi, u.cyLo), df_mul_f(scale, py));
    if (in_main_bulbs(cx.x, cy.x)) return inside_orbit();

    float2 x = float2(0.0f), y = float2(0.0f);
    float2 x2 = float2(0.0f), y2 = float2(0.0f);
    // Brent-style periodicity check. Iteration is deterministic, so an exact
    // repeat means the orbit is periodic and can never escape.
    float2 sx = x, sy = y;
    uint lap = 0u, lapLength = 8u;
    for (uint i = 0u; i < u.maxIter; ++i) {
        float2 xy = df_mul(x, y);
        y = df_add(xy * 2.0f, cy);
        x = df_add(df_sub(x2, y2), cx);
        x2 = df_sqr(x);
        y2 = df_sqr(y);
        float r2 = x2.x + y2.x;
        if (r2 > kEscape2) return escaped_orbit(i, r2);
        if (all(x == sx) && all(y == sy)) return inside_orbit();
        if (++lap == lapLength) {
            lap = 0u;
            lapLength <<= 1;
            sx = x;
            sy = y;
        }
    }
    return inside_orbit();
}

#else

static Orbit iterate(float px, float py, constant Uniforms& u) {
    float cx = u.cxHi + px * u.scaleHi;
    float cy = u.cyHi + py * u.scaleHi;
    if (in_main_bulbs(cx, cy)) return inside_orbit();

    float x = 0.0f, y = 0.0f, x2 = 0.0f, y2 = 0.0f;
    float sx = 0.0f, sy = 0.0f;
    uint lap = 0u, lapLength = 8u;
    for (uint i = 0u; i < u.maxIter; ++i) {
        y = 2.0f * x * y + cy;
        x = x2 - y2 + cx;
        x2 = x * x;
        y2 = y * y;
        float r2 = x2 + y2;
        if (r2 > kEscape2) return escaped_orbit(i, r2);
        if (x == sx && y == sy) return inside_orbit();
        if (++lap == lapLength) {
            lap = 0u;
            lapLength <<= 1;
            sx = x;
            sy = y;
        }
    }
    return inside_orbit();
}

#endif

// ---- colouring ----

// The classic Ultra Fractal style blue / white / orange gradient.
static float3 gradient_palette(float t) {
    const float3 c0 = float3(  0.0f,   7.0f, 100.0f) / 255.0f;
    const float3 c1 = float3( 32.0f, 107.0f, 203.0f) / 255.0f;
    const float3 c2 = float3(237.0f, 255.0f, 255.0f) / 255.0f;
    const float3 c3 = float3(255.0f, 170.0f,   0.0f) / 255.0f;
    const float3 c4 = float3(  0.0f,   2.0f,   0.0f) / 255.0f;
    t = fract(t);
    if (t < 0.16f)   return mix(c0, c1, t / 0.16f);
    if (t < 0.42f)   return mix(c1, c2, (t - 0.16f) / 0.26f);
    if (t < 0.6425f) return mix(c2, c3, (t - 0.42f) / 0.2225f);
    if (t < 0.8575f) return mix(c3, c4, (t - 0.6425f) / 0.215f);
    return mix(c4, c0, (t - 0.8575f) / 0.1425f);
}

// Cosine palettes: a + b * cos(2π (c t + d)).
static float3 cosine_palette(float t, float3 c, float3 d) {
    return 0.5f + 0.5f * cos(6.2831853f * (c * t + d));
}

static float3 palette_color(float t, uint palette) {
    switch (palette) {
        case 1u:  return cosine_palette(t, float3(1.0f, 1.0f, 1.0f), float3(0.00f, 0.10f, 0.20f));
        case 2u:  return cosine_palette(t, float3(1.0f, 1.0f, 1.0f), float3(0.30f, 0.20f, 0.20f));
        case 3u:  return cosine_palette(t, float3(1.0f, 1.0f, 0.5f), float3(0.80f, 0.90f, 0.30f));
        default:  return gradient_palette(t);
    }
}

static float3 shade(Orbit o, constant Uniforms& u) {
    if (u.colorMode == 0u) {
        // Continuous escape time: no banding.
        float mu = o.n + 1.0f - log2(0.5f * log2(o.r2));
        return palette_color(mu * u.colorDensity, u.palette);
    }
    // Classic bands: integer escape count, alternate bands slightly darker.
    float darken = (uint(o.n) & 1u) ? 0.82f : 1.0f;
    return palette_color(o.n * u.colorDensity, u.palette) * darken;
}

fragment float4 fragment_main(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    // Pixel offset from the view centre, y up.
    float px = in.position.x - 0.5f * u.width;
    float py = 0.5f * u.height - in.position.y;
    Orbit o = iterate(px, py, u);
    if (o.inside) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    return float4(shade(o, u), 1.0f);
}
"""#
