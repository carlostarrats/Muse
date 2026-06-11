//
//  BurnUp.metal
//  Muse
//
//  Burn-up delete (polish spec §4): the layer chars from the edges inward
//  as progress goes 0→1 — char band, hot ember frontier, and drifting
//  ember particles in the burned-out region. Pure function of
//  (position, size, progress, seed) so it chains after fluidDistort in
//  the same layerEffect stack.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float bu_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float bu_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = bu_hash(i);
    float b = bu_hash(i + float2(1, 0));
    float c = bu_hash(i + float2(0, 1));
    float d = bu_hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

[[ stitchable ]]
half4 burnUp(float2 position,
             SwiftUI::Layer layer,
             float2 size,
             float progress,
             float seed) {
    half4 src = layer.sample(position);
    if (progress <= 0.001) { return src; }

    float2 uv = position / max(size, float2(1.0));
    // 0 at the border, 1 at the center
    float2 d2 = min(uv, 1.0 - uv);
    float edge = 2.0 * min(d2.x, d2.y);
    // crackle the frontier
    float n = bu_noise(uv * 7.0 + seed * 13.7);
    float local = edge + (n - 0.5) * 0.45;
    // overshoot so the center is fully burned by progress = 1
    float front = progress * 1.45;

    const float charW = 0.07;
    const float glowW = 0.12;

    if (local < front - charW) {
        // burned away — transparent, with sparse embers drifting upward
        float2 cell = uv * 16.0 + float2(0.0, progress * 6.0);
        float2 ci = floor(cell);
        float h = bu_hash(ci + seed);
        if (h > 0.93) {
            float2 cf = fract(cell) - 0.5;
            float fade = (1.0 - progress) * smoothstep(0.35, 0.0, length(cf));
            half g = half(fade);
            return half4(half3(1.0, 0.5, 0.15) * g, g * half(0.85));
        }
        return half4(0.0);
    }
    if (local < front) {
        // charred band: near-black crackle
        half k = half(0.55 + 0.45 * n);
        half3 charC = half3(0.06, 0.035, 0.025) * k;
        return half4(charC * src.a, src.a);
    }
    if (local < front + glowW) {
        // hot glow just ahead of the frontier
        float t = 1.0 - (local - front) / glowW;
        half g = half(t * t);
        return half4(src.rgb + half3(1.0, 0.45, 0.12) * g * src.a, src.a);
    }
    return src;
}
