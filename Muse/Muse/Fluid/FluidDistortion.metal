#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]]
half4 fluidDistort(float2 position,
                   SwiftUI::Layer layer,
                   texture2d<half> dispMap,
                   float2 tileOrigin,
                   float2 viewportSize) {
    float2 globalPos = position + tileOrigin;
    float2 uv = globalPos / viewportSize;
    uv = clamp(uv, float2(0.001), float2(0.999));

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 d = dispMap.sample(s, uv);

    float2 displacement;
    displacement.x = (float(d.r) - 0.5h) * 2.0 * 40.0;
    displacement.y = (float(d.g) - 0.5h) * 2.0 * 40.0;

    return layer.sample(position + displacement);
}
