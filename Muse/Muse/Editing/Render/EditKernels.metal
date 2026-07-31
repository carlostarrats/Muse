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
