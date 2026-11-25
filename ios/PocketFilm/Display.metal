#include <metal_stdlib>
using namespace metal;
struct PocketVertex { float4 position [[position]]; float2 uv; };
vertex PocketVertex pocketVertex(uint id [[vertex_id]], constant float2& scale [[buffer(0)]]) {
    constexpr float2 p[] = {{-1,1},{-1,-1},{1,1},{1,1},{-1,-1},{1,-1}};
    constexpr float2 uv[] = {{0,0},{0,1},{1,0},{1,0},{0,1},{1,1}};
    return {float4(p[id] * scale, 0, 1), uv[id]};
}
fragment float4 pocketFragment(PocketVertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(s, v.uv).rgb, 1);
}

kernel void pocketFotufilm(
    device const float4* input [[buffer(0)]],
    constant float& exposureGain [[buffer(1)]],
    texture3d<float, access::sample> cube [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    uint2 pixel [[thread_position_in_grid]]
) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    constexpr sampler lookup(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 rgb = input[pixel.y * output.get_width() + pixel.x].rgb;
    // Match the baker's logarithmic sampling of scene-linear Rec.2020 in [0, 8].
    float3 position = log2(1.0f + 32.0f * clamp(rgb * exposureGain, 0.0f, 8.0f)) / log2(257.0f);
    float dimension = float(cube.get_width());
    float3 center = (position * (dimension - 1.0f) + 0.5f) / dimension;
    output.write(half4(half3(cube.sample(lookup, center).rgb), 1.0h), pixel);
}
