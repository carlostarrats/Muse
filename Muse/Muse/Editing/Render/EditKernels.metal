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
