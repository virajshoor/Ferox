// Ferox — hybrid ray-traced effects (Metal ray tracing, Apple family 6+ / Mac2).
//
// Rays are traced from the depth/normal prepass, so primary visibility stays rasterised.
// Every kernel writes a noisy, low-sample signal at `resolutionScale`; `rtTemporal` and
// `rtAtrous` turn it into a stable image.
//
// Limitations (documented in Docs/08-Ray-Tracing.md):
//  • Geometry is treated as opaque — alpha-tested foliage casts solid shadows.
//  • Reflection hits are shaded with per-instance constant material values (no texture
//    lookups at the hit point) and a sun + ambient term; this is a deliberate cost trade.
//  • Skinned meshes are excluded from the acceleration structure.

#include <metal_raytracing>
using namespace raytracing;

struct RTUniforms {
    float4 params;   // x AO radius, y max reflection roughness, z sun cone half-angle (rad), w frame index
    uint4 size;      // xy output size, z rays per pixel, w flags (bit 0: denoise history valid)
    float4 denoise;  // x à-trous step width, y depth sigma, z normal power, w temporal blend (current weight)
    float4 depthSize;  // xy full-resolution depth size, zw 1/output size
};

/// Constant shading values for reflection hits, indexed by acceleration-structure instance id.
struct RTInstanceMaterial {
    float4 albedoRoughness;   // rgb linear albedo, a roughness
    float4 emissiveMetallic;  // rgb emissive, a metallic
};

#define RT_BUF_UNIFORMS 0
#define RT_BUF_ACCEL 1
#define RT_BUF_MATERIALS 3

typedef intersector<triangle_data, instancing> RTIntersector;
typedef intersection_result<triangle_data, instancing> RTHit;

/// Fetches the prepass sample that corresponds to an output pixel of the (possibly
/// lower-resolution) ray-traced target.
inline uint2 depthPixel(uint2 gid, constant RTUniforms &u) {
    float2 uv = (float2(gid) + 0.5f) * u.depthSize.zw;
    return min(uint2(uv * u.depthSize.xy), uint2(u.depthSize.xy) - 1u);
}

inline float3 decodeNormal(float4 nr) { return normalize(nr.xyz * 2.0f - 1.0f); }

/// Offsets a ray origin along the normal, scaled with distance to limit self-intersection.
inline float3 offsetOrigin(float3 p, float3 n, float3 camera) {
    float d = length(p - camera);
    return p + n * (0.002f + d * 0.0005f);
}

inline float2 rtNoise(uint2 gid, uint sampleIndex, float frame) {
    uint seed = hash(gid.x * 1973u + gid.y * 9277u + uint(frame) * 26699u + sampleIndex * 104729u);
    return float2(random01(seed), random01(hash(seed)));
}

/// Uniformly samples a cone around `axis` with the given half-angle.
inline float3 sampleCone(float2 u, float3 axis, float halfAngle) {
    float cosMax = cos(halfAngle);
    float cosTheta = mix(1.0f, cosMax, u.x);
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float phi = 2.0f * FEROX_PI * u.y;
    float3 t, b;
    basis(axis, t, b);
    return normalize(t * (cos(phi) * sinTheta) + b * (sin(phi) * sinTheta) + axis * cosTheta);
}

// MARK: - Shadows

kernel void rtShadows(constant RTUniforms &u [[buffer(RT_BUF_UNIFORMS)]],
                      instance_acceleration_structure accel [[buffer(RT_BUF_ACCEL)]],
                      constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                      depth2d<float, access::read> depthTex [[texture(0)]],
                      texture2d<float, access::read> normalTex [[texture(1)]],
                      texture2d<float, access::write> outTex [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
    uint2 dp = depthPixel(gid, u);
    float depth = depthTex.read(dp);
    if (depth <= 0.0f) {  // sky (reverse-Z)
        outTex.write(float4(1.0f), gid);
        return;
    }
    float2 uv = (float2(dp) + 0.5f) / u.depthSize.xy;
    float3 p = worldFromDepth(uv, depth, frame.inverseViewProjection);
    float3 n = decodeNormal(normalTex.read(dp));
    float3 L = normalize(frame.sunDirection.xyz);
    if (dot(n, L) <= 0.0f) {
        outTex.write(float4(0.0f), gid);
        return;
    }

    RTIntersector isect;
    isect.accept_any_intersection(true);
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);

    uint count = max(u.size.z, 1u);
    float visible = 0.0f;
    float3 origin = offsetOrigin(p, n, frame.cameraPosition.xyz);
    for (uint i = 0; i < count; i++) {
        float3 dir = sampleCone(rtNoise(gid, i, u.params.w), L, u.params.z);
        ray r(origin, dir, 0.0f, 1e4f);
        RTHit hit = isect.intersect(r, accel, 0x01u);
        visible += hit.type == intersection_type::none ? 1.0f : 0.0f;
    }
    outTex.write(float4(visible / float(count)), gid);
}

// MARK: - Ambient occlusion

kernel void rtAO(constant RTUniforms &u [[buffer(RT_BUF_UNIFORMS)]],
                 instance_acceleration_structure accel [[buffer(RT_BUF_ACCEL)]],
                 constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                 depth2d<float, access::read> depthTex [[texture(0)]],
                 texture2d<float, access::read> normalTex [[texture(1)]],
                 texture2d<float, access::write> outTex [[texture(2)]],
                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
    uint2 dp = depthPixel(gid, u);
    float depth = depthTex.read(dp);
    if (depth <= 0.0f) {
        outTex.write(float4(1.0f), gid);
        return;
    }
    float2 uv = (float2(dp) + 0.5f) / u.depthSize.xy;
    float3 p = worldFromDepth(uv, depth, frame.inverseViewProjection);
    float3 n = decodeNormal(normalTex.read(dp));

    RTIntersector isect;
    isect.accept_any_intersection(true);
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);

    float radius = max(u.params.x, 0.01f);
    uint count = max(u.size.z, 1u);
    float occlusion = 0.0f;
    float3 origin = offsetOrigin(p, n, frame.cameraPosition.xyz);
    for (uint i = 0; i < count; i++) {
        float3 dir = cosineSampleHemisphere(rtNoise(gid, i + 17u, u.params.w), n);
        ray r(origin, dir, 0.0f, radius);
        RTHit hit = isect.intersect(r, accel, 0x01u);
        if (hit.type != intersection_type::none) {
            // Nearer hits occlude more; smooth falloff avoids a hard radius ring.
            float t = saturate(hit.distance / radius);
            occlusion += 1.0f - t * t;
        }
    }
    outTex.write(float4(1.0f - occlusion / float(count)), gid);
}

// MARK: - Reflections

kernel void rtReflections(constant RTUniforms &u [[buffer(RT_BUF_UNIFORMS)]],
                          instance_acceleration_structure accel [[buffer(RT_BUF_ACCEL)]],
                          constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                          const device RTInstanceMaterial *materials [[buffer(RT_BUF_MATERIALS)]],
                          depth2d<float, access::read> depthTex [[texture(0)]],
                          texture2d<float, access::read> normalTex [[texture(1)]],
                          texturecube<float> environment [[texture(2)]],
                          texture2d<float, access::write> outTex [[texture(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
    constexpr sampler linearS(filter::linear, mip_filter::linear);
    uint2 dp = depthPixel(gid, u);
    float depth = depthTex.read(dp);
    float4 nr = normalTex.read(dp);
    float roughness = nr.w;
    if (depth <= 0.0f || roughness > u.params.y) {
        outTex.write(float4(0.0f), gid);  // alpha 0: forward pass falls back to probes/IBL
        return;
    }
    float2 uv = (float2(dp) + 0.5f) / u.depthSize.xy;
    float3 p = worldFromDepth(uv, depth, frame.inverseViewProjection);
    float3 n = decodeNormal(nr);
    float3 V = normalize(frame.cameraPosition.xyz - p);

    RTIntersector isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    RTIntersector shadowIsect;
    shadowIsect.accept_any_intersection(true);
    shadowIsect.assume_geometry_type(geometry_type::triangle);
    shadowIsect.force_opacity(forced_opacity::opaque);

    uint count = max(u.size.z, 1u);
    float3 sum = float3(0.0f);
    float3 L = normalize(frame.sunDirection.xyz);
    float mipCount = float(environment.get_num_mip_levels());
    float3 origin = offsetOrigin(p, n, frame.cameraPosition.xyz);
    for (uint i = 0; i < count; i++) {
        float3 H = importanceSampleGGX(rtNoise(gid, i + 31u, u.params.w), n, max(roughness, 0.02f));
        float3 R = reflect(-V, H);
        if (dot(R, n) <= 0.0f) { R = reflect(-V, n); }
        ray r(origin, R, 0.0f, 1e4f);
        RTHit hit = isect.intersect(r, accel, 0x01u);
        if (hit.type == intersection_type::none) {
            sum += environment.sample(linearS, R, level(roughness * (mipCount - 1.0f))).rgb * frame.exposure.w;
            continue;
        }
        RTInstanceMaterial m = materials[hit.instance_id];
        float3 hp = origin + R * hit.distance;
        // No hit normal is available without vertex fetch; treat the surface as facing the ray.
        float3 hn = -R;
        ray sr(hp + hn * 0.01f, L, 0.0f, 1e4f);
        float sunVis = shadowIsect.intersect(sr, accel, 0x01u).type == intersection_type::none ? 1.0f : 0.0f;
        float3 albedo = m.albedoRoughness.rgb * (1.0f - m.emissiveMetallic.a * 0.5f);
        float3 lit = albedo * (frame.ambient.rgb + frame.sunColor.rgb * frame.sunColor.a * sunVis * saturate(dot(hn, L) * 0.5f + 0.5f) / FEROX_PI);
        sum += lit + m.emissiveMetallic.rgb;
    }
    float3 color = min(sum / float(count), float3(64000.0f));
    // Confidence fades out towards the roughness cut-off so the IBL blend is seamless.
    float confidence = 1.0f - smoothstep(u.params.y * 0.7f, u.params.y, roughness);
    outTex.write(float4(color, confidence), gid);
}

// MARK: - Denoising

/// Temporal accumulation with motion reprojection and neighbourhood clamping.
kernel void rtTemporal(constant RTUniforms &u [[buffer(RT_BUF_UNIFORMS)]],
                       texture2d<float, access::read> current [[texture(0)]],
                       texture2d<float> history [[texture(1)]],
                       texture2d<float> motion [[texture(2)]],
                       texture2d<float, access::write> outTex [[texture(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
    constexpr sampler linearS(filter::linear, address::clamp_to_edge);
    float4 c = current.read(gid);
    float4 mn = c, mx = c;
    int2 maxP = int2(u.size.xy) - 1;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float4 s = current.read(uint2(clamp(int2(gid) + int2(x, y), int2(0), maxP)));
            mn = min(mn, s);
            mx = max(mx, s);
        }
    }
    float2 uv = (float2(gid) + 0.5f) * u.depthSize.zw;
    float2 prevUV = uv - motion.sample(linearS, uv).xy;
    bool valid = (u.size.w & 1u) != 0u && all(prevUV >= 0.0f) && all(prevUV <= 1.0f);
    if (!valid) {
        outTex.write(c, gid);
        return;
    }
    float4 h = clamp(history.sample(linearS, prevUV), mn, mx);
    outTex.write(mix(h, c, saturate(u.denoise.w)), gid);
}

/// One iteration of an edge-aware à-trous wavelet filter (run with step widths 1, 2, 4…).
kernel void rtAtrous(constant RTUniforms &u [[buffer(RT_BUF_UNIFORMS)]],
                     constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                     texture2d<float, access::read> input [[texture(0)]],
                     depth2d<float, access::read> depthTex [[texture(1)]],
                     texture2d<float, access::read> normalTex [[texture(2)]],
                     texture2d<float, access::write> outTex [[texture(3)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
    const float kernelW[3] = { 3.0f / 8.0f, 1.0f / 4.0f, 1.0f / 16.0f };
    uint2 dp = depthPixel(gid, u);
    float centerDepth = linearDepth(depthTex.read(dp), frame.inverseProjection);
    float3 centerN = decodeNormal(normalTex.read(dp));
    int step = max(int(u.denoise.x), 1);
    int2 maxP = int2(u.size.xy) - 1;

    float4 sum = float4(0.0f);
    float wsum = 0.0f;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            uint2 p = uint2(clamp(int2(gid) + int2(x, y) * step, int2(0), maxP));
            uint2 sp = depthPixel(p, u);
            float d = linearDepth(depthTex.read(sp), frame.inverseProjection);
            float3 nn = decodeNormal(normalTex.read(sp));
            float wd = exp(-abs(d - centerDepth) / max(u.denoise.y * centerDepth, 1e-4f));
            float wn = pow(saturate(dot(centerN, nn)), max(u.denoise.z, 1.0f));
            float w = kernelW[abs(x)] * kernelW[abs(y)] * wd * wn;
            sum += input.read(p) * w;
            wsum += w;
        }
    }
    outTex.write(sum / max(wsum, 1e-6f), gid);
}
