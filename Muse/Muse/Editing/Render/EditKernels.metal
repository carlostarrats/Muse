//
//  EditKernels.metal
//  Muse
//
//  Stitchable Core Image kernels. These compile into the target's DEFAULT
//  metallib (no `-fcikernel` — that flag belongs to the deprecated CIKL path)
//  and load by function name at runtime.
//
//  Both kernels operate on UN-CLAMPED linear working-space data: values above
//  1.0 are real highlight headroom, not error, and must survive.
//

#include <CoreImage/CoreImage.h>
using namespace metal;

/// Rec.709 luminance — the same weights every other stage uses, so "midtone"
/// means one thing across the whole chain.
static inline float lumaOf(float3 rgb) {
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Highlights / Shadows / Whites / Blacks as luminance-banded gains in
/// EXPOSURE space.
///
/// One multiplicative gain per pixel applied to all three channels, so hue is
/// preserved by construction — the failure mode of the naive alternative
/// (per-channel tone curves) is that recovering a blown sky drags it cyan.
///
/// Bands are triangular weights over log2 luminance: Highlights and Shadows
/// peak at their centres and fall off, Whites and Blacks ramp toward the ends.
/// At all-zero params every weight is multiplied by zero, so `gain` is
/// exactly pow(2, 0) == 1 — an exact identity, not an approximate one.
extern "C" [[stitchable]] float4 toneBands(coreimage::sample_t s, float highlights, float shadows,
                            float whites, float blacks) {
    float luma = lumaOf(s.rgb);
    float logLuma = log2(max(luma, 1e-6f));

    // Owner-tunable; expect these to move once real photos are graded.
    const float highlightsCenter = -1.0f, highlightsWidth = 2.0f;
    const float shadowsCenter = -5.0f, shadowsWidth = 2.0f;
    const float whitesToe = -1.0f, whitesWidth = 2.0f;
    const float blacksToe = -7.0f, blacksWidth = 2.0f;
    const float maxGainEV = 1.5f;

    float wHighlights = clamp(1.0f - fabs(logLuma - highlightsCenter) / highlightsWidth, 0.0f, 1.0f);
    float wShadows = clamp(1.0f - fabs(logLuma - shadowsCenter) / shadowsWidth, 0.0f, 1.0f);
    float wWhites = clamp((logLuma - whitesToe) / whitesWidth, 0.0f, 1.0f);
    float wBlacks = clamp(1.0f - (logLuma - blacksToe) / blacksWidth, 0.0f, 1.0f);

    float gainEV = (highlights * wHighlights
                  + shadows * wShadows
                  + whites * wWhites
                  + blacks * wBlacks) * maxGainEV;
    float gain = exp2(gainEV);
    return float4(s.rgb * gain, s.a);
}

/// Clarity / Texture: midtone-weighted local contrast (the Pat David
/// formulation). The Swift side invokes it twice at different blur radii —
/// a wide blur reads as Clarity, a tight one as Texture.
///
/// The midtone weight is what keeps it from crushing blacks and clipping
/// highlights: it peaks at luma 0.5 and reaches zero at both ends, so the
/// extremes are left alone no matter how hard the slider is pushed.
extern "C" [[stitchable]] float4 clarityTexture(coreimage::sample_t base, coreimage::sample_t blurred,
                                 float amount) {
    float luma = lumaOf(base.rgb);
    float midtoneWeight = clamp(1.0f - fabs(clamp(luma, 0.0f, 1.0f) * 2.0f - 1.0f), 0.0f, 1.0f);
    float3 result = base.rgb + amount * midtoneWeight * (base.rgb - blurred.rgb);
    return float4(result, base.a);
}

// MARK: - Spec 05

/// zebraStripes: diagonal-stripe overlay marking clipped pixels on the
/// DISPLAY-referred canvas output. Any channel ≥ highThreshold gets red/white
/// stripes; luminance ≤ lowThreshold gets blue ones; everything else passes
/// through untouched.
///
/// Raw-sensor (pre-demosaic) clipping is deliberately NOT approximated here —
/// CIRAWFilter exposes no cheap tap for it, and a guessed stripe is worse than
/// an honest one. What the zebras mean is display clipping.
///
/// `phase` shifts the stripe origin so the pattern stays put across a canvas
/// resize; it is not an animation.
extern "C" [[stitchable]] float4 zebraStripes(coreimage::sample_t s, float highThreshold,
                                             float lowThreshold, float phase,
                                             coreimage::destination dest) {
    const float zebraPeriodPx = 8.0f;
    float2 coord = dest.coord();
    float diagonal = fmod(coord.x + coord.y + phase, zebraPeriodPx);
    bool stripeOn = diagonal < zebraPeriodPx * 0.5f;

    bool clippedHigh = s.r >= highThreshold || s.g >= highThreshold || s.b >= highThreshold;
    float luma = lumaOf(s.rgb);
    bool clippedLow = luma <= lowThreshold;

    if (clippedHigh) {
        float3 stripeColor = stripeOn ? float3(1.0f, 1.0f, 1.0f) : float3(1.0f, 0.0f, 0.0f);
        return float4(stripeColor, s.a);
    }
    if (clippedLow) {
        float3 stripeColor = stripeOn ? float3(0.0f, 0.3f, 1.0f) : s.rgb;
        return float4(stripeColor, s.a);
    }
    return s;
}

/// tzLog2Luma: the tone-zone guide map. log2 of Rec.709 luminance, replicated
/// into all three channels so the box-blur chain can treat it as an image.
/// The guide MUST be in the log domain: the zone weights are defined over EV,
/// and a linear-luminance guide would bunch eight of the nine zones into the
/// bottom stop.
extern "C" [[stitchable]] float4 tzLog2Luma(coreimage::sample_t s) {
    float v = log2(max(lumaOf(s.rgb), 1e-6f));
    return float4(v, v, v, 1.0f);
}

/// tzSquare: writes (value, value²) so ONE box blur yields both the local mean
/// and the raw second moment the variance needs.
extern "C" [[stitchable]] float4 tzSquare(coreimage::sample_t s) {
    float v = s.r;
    return float4(v, v * v, 0.0f, 1.0f);
}

/// tzLinearCoeffs: the guided filter's local linear model from the blurred
/// (mean, meanOfSquares) pair — a = var/(var+ε), b = mean·(1−a).
extern "C" [[stitchable]] float4 tzLinearCoeffs(coreimage::sample_t blurredSquare, float epsilon) {
    float mean = blurredSquare.r;
    float meanOfSquares = blurredSquare.g;
    float variance = max(meanOfSquares - mean * mean, 0.0f);
    float a = variance / (variance + epsilon);
    float b = mean * (1.0f - a);
    return float4(a, b, 0.0f, 1.0f);
}

/// tzApplyCoeffs: applies the (blurred) linear model to the ORIGINAL guide —
/// the edge-aware smoothed log2-luminance. THIS is the smoothed EV map the
/// render stage, the stats tap and the zone overlay all share.
extern "C" [[stitchable]] float4 tzApplyCoeffs(coreimage::sample_t guide,
                                               coreimage::sample_t blurredCoeffs) {
    float smoothed = blurredCoeffs.r * guide.r + blurredCoeffs.g;
    return float4(smoothed, smoothed, smoothed, 1.0f);
}

/// toneZoneGain: outRGB = inRGB · exp2(Σ wᵢ·gainᵢ·maxZoneEV) — a single scalar
/// gain on all three channels, so hue is preserved by construction. Mirrors
/// `ToneZoneMath.gainEV`; the two are pinned together through the render
/// goldens. Exact identity when all nine gains are zero.
extern "C" [[stitchable]] float4 toneZoneGain(coreimage::sample_t s, coreimage::sample_t smoothedEV,
                                              float g0, float g1, float g2, float g3, float g4,
                                              float g5, float g6, float g7, float g8) {
    const float evFloor = -8.0f, evCeiling = 0.0f;
    const float maxZoneEV = 2.0f;
    const int zoneCount = 9;
    float gains[9] = { g0, g1, g2, g3, g4, g5, g6, g7, g8 };
    float ev = clamp(smoothedEV.r, evFloor, evCeiling);
    float step = (evCeiling - evFloor) / float(zoneCount - 1);

    float gainEV = 0.0f;
    float weightSum = 0.0f;
    for (int i = 0; i < zoneCount; i++) {
        float center = evFloor + float(i) * step;
        float distance = fabs(ev - center) / step;
        float w = distance < 1.0f ? 0.5f * (1.0f + cos(3.14159265f * distance)) : 0.0f;
        gainEV += w * gains[i] * maxZoneEV;
        weightSum += w;
    }
    if (weightSum > 0.0f) { gainEV /= weightSum; }

    return float4(s.rgb * exp2(gainEV), s.a);
}

/// zoneHatch: 45° hatch over pixels whose HOVERED zone weight ≥ the floor,
/// with everything else dimmed so the hatch reads. Uses the same shared
/// smoothed-EV mask as the render stage — one mask, three consumers.
extern "C" [[stitchable]] float4 zoneHatch(coreimage::sample_t s, coreimage::sample_t smoothedEV,
                                           float zoneIndex, coreimage::destination dest) {
    const float evFloor = -8.0f, evCeiling = 0.0f;
    const int zoneCount = 9;
    const float overlayWeightFloor = 0.5f;
    const float hatchPeriodPx = 10.0f;

    float ev = clamp(smoothedEV.r, evFloor, evCeiling);
    float step = (evCeiling - evFloor) / float(zoneCount - 1);
    float center = evFloor + zoneIndex * step;
    float distance = fabs(ev - center) / step;
    float weight = distance < 1.0f ? 0.5f * (1.0f + cos(3.14159265f * distance)) : 0.0f;

    if (weight < overlayWeightFloor) {
        return float4(s.rgb * 0.8f, s.a);
    }

    float2 coord = dest.coord();
    bool hatchOn = fmod(coord.x + coord.y, hatchPeriodPx) < hatchPeriodPx * 0.5f;
    return float4(hatchOn ? float3(1.0f, 1.0f, 1.0f) : s.rgb, s.a);
}

/// lutMix: mix(base, lutted, strength). Exact identity at strength 0 — which
/// the model normalizes away anyway, so this is defence in depth.
extern "C" [[stitchable]] float4 lutMix(coreimage::sample_t base, coreimage::sample_t lutted,
                                        float strength) {
    return float4(mix(base.rgb, lutted.rgb, strength), base.a);
}

// MARK: - Stage B

/// Eight-band HSL. Bands are centred every 45° starting at red (0°), and a
/// pixel's influence falls off linearly to zero at the neighbouring centres —
/// so the weights of any two adjacent bands always sum to 1 and there is no
/// visible seam where one band hands over to the next.
///
/// A grey pixel has no hue to target and returns untouched, which is also what
/// makes an all-zero parameter set an exact identity.
extern "C" [[stitchable]] float4 hslAdjust(coreimage::sample_t s,
                                           float h0, float h1, float h2, float h3,
                                           float h4, float h5, float h6, float h7,
                                           float s0, float s1, float s2, float s3,
                                           float s4, float s5, float s6, float s7,
                                           float l0, float l1, float l2, float l3,
                                           float l4, float l5, float l6, float l7) {
    float hueArr[8] = {h0, h1, h2, h3, h4, h5, h6, h7};
    float satArr[8] = {s0, s1, s2, s3, s4, s5, s6, s7};
    float lumArr[8] = {l0, l1, l2, l3, l4, l5, l6, l7};

    float3 c = max(s.rgb, 0.0f);
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float delta = mx - mn;
    if (delta < 1e-6f || mx < 1e-6f) { return s; }

    float hue;
    if (mx == c.r)      { hue = fmod((c.g - c.b) / delta + 6.0f, 6.0f); }
    else if (mx == c.g) { hue = (c.b - c.r) / delta + 2.0f; }
    else                { hue = (c.r - c.g) / delta + 4.0f; }
    hue = fmod(hue * 60.0f + 360.0f, 360.0f);

    float pos = hue / 45.0f;                     // 0…8 across the eight bands
    int lo = ((int)floor(pos)) % 8;
    int hi = (lo + 1) % 8;
    float t = pos - floor(pos);

    float dHue = mix(hueArr[lo], hueArr[hi], t);
    float dSat = mix(satArr[lo], satArr[hi], t);
    float dLum = mix(lumArr[lo], lumArr[hi], t);

    // ±30° of rotation at full slider — enough to move a leaf from green to
    // yellow, not enough to turn it magenta by accident.
    hue = fmod(hue + dHue * 30.0f + 360.0f, 360.0f);
    float sat = clamp((delta / mx) * (1.0f + dSat), 0.0f, 1.0f);
    float val = mx * (1.0f + dLum * 0.5f);

    float cc = val * sat;
    float xx = cc * (1.0f - fabs(fmod(hue / 60.0f, 2.0f) - 1.0f));
    float m = val - cc;
    float3 o;
    if      (hue <  60.0f) o = float3(cc, xx, 0.0f);
    else if (hue < 120.0f) o = float3(xx, cc, 0.0f);
    else if (hue < 180.0f) o = float3(0.0f, cc, xx);
    else if (hue < 240.0f) o = float3(0.0f, xx, cc);
    else if (hue < 300.0f) o = float3(xx, 0.0f, cc);
    else                   o = float3(cc, 0.0f, xx);
    return float4(o + m, s.a);
}

/// Split toning. Weights each pixel toward a shadow tint or a highlight tint by
/// its luma, with `balance` sliding the crossover point. Display-referred: it
/// runs after the curve and the LUT, because that is the encoding the grade is
/// being judged in.
///
/// Both amounts at zero leave every mix() factor at zero, so this is an exact
/// identity when neutral.
extern "C" [[stitchable]] float4 splitTone(coreimage::sample_t s,
                                           float shR, float shG, float shB, float shAmt,
                                           float hiR, float hiG, float hiB, float hiAmt,
                                           float balance) {
    float3 c = s.rgb;
    float y = clamp(lumaOf(c), 0.0f, 1.0f);
    // balance −1 pushes the crossover down (more of the frame reads as
    // highlight), +1 pushes it up.
    float pivot = clamp(0.5f - balance * 0.4f, 0.05f, 0.95f);
    float hiW = smoothstep(pivot - 0.35f, pivot + 0.35f, y);
    float shW = 1.0f - hiW;

    float3 shadowTint = float3(shR, shG, shB);
    float3 highlightTint = float3(hiR, hiG, hiB);
    c = mix(c, c * (1.0f - shAmt) + shadowTint * shAmt, shW * shAmt > 0.0f ? shW : 0.0f);
    c = mix(c, c * (1.0f - hiAmt) + highlightTint * hiAmt, hiW * hiAmt > 0.0f ? hiW : 0.0f);
    return float4(c, s.a);
}

/// Film grain.
///
/// `cellPx` arrives ALREADY RESOLVED from a long-edge fraction, so the same
/// photo grains identically at a 320px thumbnail and a 60 MP export — the one
/// bug class that shows up as "the grid doesn't match what I edited". `seed`
/// comes from the file's content hash, never from time or position alone, for
/// the same reason.
static inline float grainHash(float2 p, float seed) {
    float h = dot(p, float2(127.1f, 311.7f)) + seed * 43.7f;
    return fract(sin(h) * 43758.5453123f);
}

// `coreimage::destination` must be the LAST parameter, and a kernel that pairs
// it with `sample_t` is still a CIColorKernel — not a general CIKernel, which
// is what `coreimage::sampler` would make it. Getting that wrong makes the
// function simply fail to load, silently, at runtime.
extern "C" [[stitchable]] float4 grain(coreimage::sample_t s,
                                       float amount, float cellPx, float roughness,
                                       float seed,
                                       coreimage::destination dest) {
    float2 p = dest.coord() / max(cellPx, 1.0f);
    float2 i = floor(p);
    float2 f = fract(p);
    // Bilinear value noise. Raw per-cell noise reads as digital blocks; the
    // smoothstep interpolation is what makes it read as film.
    float a = grainHash(i, seed);
    float b = grainHash(i + float2(1.0f, 0.0f), seed);
    float c = grainHash(i + float2(0.0f, 1.0f), seed);
    float d = grainHash(i + float2(1.0f, 1.0f), seed);
    float2 u = f * f * (3.0f - 2.0f * f);
    float n = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);

    // Roughness pushes the noise toward its extremes.
    n = mix(n, step(0.5f, n), roughness);
    float delta = (n - 0.5f) * amount * 0.5f;

    // Strongest in the midtones, fading in deep shadow and clipped highlight —
    // how film actually behaves, and it keeps grain out of a black sky.
    float y = clamp(lumaOf(s.rgb), 0.0f, 1.0f);
    float weight = 1.0f - fabs(y * 2.0f - 1.0f);
    return float4(s.rgb + delta * weight, s.a);
}

/// Reinhard highlight roll-off — the macOS 14.6 tone-map fallback.
///
/// `CIToneMapHeadroom` is macOS 15.0 and Muse's floor is 14.6, so the older
/// systems need their own HDR -> SDR curve. The alternative, letting
/// `createCGImage` clamp, was measured collapsing 2.0 and 4.0 onto the same
/// 1.0 — every specular highlight becomes one flat white blob.
///
/// EXTENDED Reinhard: out = c(1 + c/h^2) / (1 + c), which maps `h` exactly to
/// 1.0 and leaves midtones close to where they were. The plain Reinhard
/// variant looks equivalent and is not — it maps h to h/2 + 0.5, so at
/// headroom 4.0 everything above ~1.6 still clipped and 2.0 and 4.0 landed on
/// the same white. Caught only by forcing this branch on a machine that would
/// otherwise take the macOS 15 path.
///
/// A linear divide would also avoid clipping, but would drag a 4.0-headroom
/// photo's midtones to a quarter brightness. It survives as HDRDecode's
/// last-resort fallback for a kernel that failed to load, not as the curve.
extern "C" [[stitchable]] float4 reinhardToneMap(coreimage::sample_t s, float h) {
    float3 c = max(s.rgb, 0.0f);
    float3 mapped = c * (1.0f + c / (h * h)) / (1.0f + c);
    return float4(clamp(mapped, 0.0f, 1.0f), s.a);
}
