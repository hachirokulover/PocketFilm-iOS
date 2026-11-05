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
