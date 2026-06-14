//
//  BurnUp.metal
//  Muse
//
//  Burn-up delete (polish spec §4): the layer chars from the edges inward as
//  progress goes 0→1 — a smooth char→ember gradient frontier, drifting embers
//  off the burning edge, and translucent flame. Pure function of
//  (position, size, progress, seed).
//
//  The look was dialed in the WebGL tuning prototype
//  (docs/superpowers/assets/burn-prototype.html) and the constants below are
//  that prototype's settings 1:1. Two things to know if you touch this:
//   - MOVEMENT (edge wobble, flame flow, ember rise) is driven by `t`, which is
//     derived from `progress`. progress is the animatable uniform, so it ticks
//     every frame during the burn — no separate time uniform needed.
//   - The frontier is a SMOOTH gaussian heat gradient, not hard color bands.
//     Re-introducing `if (band) return flatColor;` is what made it look
//     pixel-ish/cartoony. Keep it continuous.
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

    // ---- tuning constants (from burn-prototype.html) ----
    // OVERSHOOT must exceed the noisy front's max (~1.45) so the center fully
    // clears by progress≈0.94 — i.e. the image is GONE before the transition,
    // no leftover "hole" snapping away.
    const float OVERSHOOT  = 1.55;
    // 0 = concentric (eats from all borders at once), 1 = pure directional
    // sweep across the sheet. Real paper burns oblong/directional, not circular.
    const float DIRECTION_BIAS = 0.6;
    const float BIG_AMP    = 0.69,  BIG_FREQ  = 8.4;
    const float MED_AMP    = 0.122, MED_FREQ  = 23.5;
    const float FINE_AMP   = 0.006, FINE_FREQ = 124.0;
    const float WOBBLE_AMP = 0.075;
    const float FLAME_SPEED = 2.55;
    const float FLICKER    = 0.66;
    const float GLOW_WIDTH = 0.06, GLOW_CENTER = 0.008, WHITE_CORE = 0.67;
    const float CHAR_W     = 0.10, CHAR_START = 0.022, ASH_FADE = 0.064, CHAR_GRAIN = 1.22;
    const float SCORCH_W   = 0.026, SCORCH_STR = 0.50;
    const float EMB_DENSITY = 0.096, EMB_RISE = 0.6, EMB_SWAY = 1.14;
    const float EMB_SIZE   = 0.82, EMB_REACH = 0.35, EMB_TWINKLE = 0.6;
    // flames read as translucent light, not solid paint (requested)
    const float FLAME_OPACITY = 0.6;
    // progress→time scale: gives the edge/flame/embers visible motion over the burn
    const float TIME = 2.6;

    const float3 EMBER_COOL = float3(1.0,   0.420, 0.071);
    const float3 EMBER_HOT  = float3(1.0,   0.824, 0.478);
    const float3 CHAR_EDGE  = float3(0.227, 0.110, 0.047);
    const float3 CHAR_DEEP  = float3(0.020, 0.016, 0.012);
    const float3 SCORCH_COL = float3(0.420, 0.227, 0.110);

    float t = progress * TIME;
    float2 uv = position / max(size, float2(1.0));

    // Front geometry: a per-image directional sweep (oblong, burns ACROSS the
    // sheet) blended with edge-inward eating (so borders/corners still char).
    float edge = 2.0 * min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float ang = 6.2831853 * bu_hash(float2(seed * 1.7, 4.2));
    float2 dir = float2(cos(ang), sin(ang));
    float along = dot(uv - 0.5, dir) / (abs(dir.x) + abs(dir.y)) + 0.5;  // 0..1 across
    float base = mix(edge, along, DIRECTION_BIAS);

    // organic front + ragged edge + animated wobble
    float nBig  = bu_noise(uv * BIG_FREQ  + seed * 13.7);
    float nMed  = bu_noise(uv * MED_FREQ  + seed * 4.3);
    float nFine = bu_noise(uv * FINE_FREQ + seed * 8.1);
    float wob   = bu_noise(uv * MED_FREQ * 0.5 + float2(t * 0.25, -t * 0.5) + seed * 3.0) - 0.5;
    float local = base + (nBig - 0.5) * BIG_AMP + (nMed - 0.5) * MED_AMP
                       + (nFine - 0.5) * FINE_AMP + wob * WOBBLE_AMP;
    float s = local - progress * OVERSHOOT;        // <0 burned, >0 intact
    float tex = nFine * 0.6 + nMed * 0.4;

    // smooth masks
    float gone  = smoothstep(-CHAR_W, -CHAR_W - ASH_FADE, s);            // 1 = burned away
    float charM = smoothstep(CHAR_START, -CHAR_W * 0.5, s) * (1.0 - gone);

    // flame heat — smooth gaussian gradient, animated flow + flicker
    float fnoise = bu_noise(uv * float2(9.0, 15.0) + float2(0.0, -t * FLAME_SPEED) + seed * 2.0);
    float flick  = mix(1.0, 0.55 + 0.7 * fnoise, FLICKER) * max(FLICKER, 0.0001);
    float heat   = exp(-pow((s + GLOW_CENTER) / max(GLOW_WIDTH, 0.001), 2.0)) * flick;

    // base color: image → scorch → char
    float3 col = float3(src.rgb);
    float scorch = smoothstep(SCORCH_W, 0.0, s);
    col = mix(col, SCORCH_COL, scorch * SCORCH_STR * (1.0 - charM));
    float3 charC = mix(CHAR_EDGE, CHAR_DEEP, smoothstep(0.0, -CHAR_W, s)) * (0.45 + CHAR_GRAIN * tex);
    col = mix(col, charC, charM);

    // flame emission — char→orange→amber→(white core), smooth gradient
    float3 emis = mix(CHAR_DEEP, EMBER_COOL, smoothstep(0.04, 0.45, heat));
    emis = mix(emis, EMBER_HOT, smoothstep(0.45, 0.95, heat));
    emis = mix(emis, float3(1.0, 0.96, 0.82), smoothstep(0.95, 1.35, heat) * WHITE_CORE);
    emis *= heat;

    float baseA = float(src.a) * (1.0 - gone);
    // translucent flame: partial emission + a little coverage where it licks into the void
    float3 outRGB = col * baseA + emis * FLAME_OPACITY;
    float flameA = clamp(heat * FLAME_OPACITY * 0.8, 0.0, 1.0);
    float alpha = max(baseA, flameA);

    // embers: sparse, frontier-gated, swaying, twinkling — sparks off the edge
    float gate = smoothstep(-EMB_REACH, -0.005, s) * (1.0 - smoothstep(-0.005, 0.02, s));
    float3 emb = float3(0.0);
    for (int L = 0; L < 3; L++) {
        float fl = float(L);
        float sc = (7.0 + fl * 4.0) / max(EMB_SIZE, 0.2);
        float2 q = uv * sc;
        q.y += t * EMB_RISE * (0.8 + 0.3 * fl);
        q.x += sin(uv.y * 6.0 + t * 1.3 + fl * 2.1) * EMB_SWAY;
        float2 ci = floor(q), cf = fract(q) - 0.5;
        float rnd = bu_hash(ci + seed * (fl + 3.0));
        if (rnd > 1.0 - EMB_DENSITY) {
            float spark = smoothstep(0.45, 0.0, length(cf * float2(1.2, 0.85)));
            float tw = mix(1.0, 0.4 + 0.6 * sin(t * 7.0 * rnd + rnd * 40.0), EMB_TWINKLE);
            emb += mix(EMBER_COOL, EMBER_HOT, bu_hash(ci + 5.0)) * spark * tw;
        }
    }
    emb *= gate;
    outRGB += emb;
    alpha = max(alpha, max(emb.r, max(emb.g, emb.b)) * 0.9);

    return half4(half3(outRGB), half(clamp(alpha, 0.0, 1.0)));
}
