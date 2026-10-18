// Ferox — shared shader declarations.
//
// This file is prepended to every shader module by `ShaderLibrary` (runtime compilation
// keeps shader hot-reload simple). Structures must match `GPUTypes.swift` exactly.

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

#define FEROX_PI 3.14159265358979323846f

// MARK: - Shared structures (see GPUTypes.swift)

struct FrameUniforms {
    float4x4 view;
    float4x4 projection;
    float4x4 viewProjection;
    float4x4 inverseViewProjection;
    float4x4 previousViewProjection;
    float4x4 inverseProjection;
    float4x4 inverseView;
    float4x4 unjitteredViewProjection;
    float4x4 previousUnjitteredViewProjection;
    float4 cameraPosition;
    float4 viewport;
    float4 jitter;
    float4 sunDirection;
    float4 sunColor;
    float4 ambient;
    float4 fog;
    float4 clusterParams;
    uint4 clusterDims;
    uint4 lightCounts;
    float4 exposure;
    float4x4 shadowMatrices[4];
    float4 cascadeSplits;
    float4 shadowParams;
    float4 effectFlags;
};

#define FRAME_FLAG_CLUSTERED 1u
#define FRAME_FLAG_SHADOWS 2u
#define FRAME_FLAG_PCSS 4u

struct InstanceData {
    float4x4 model;
    float4x4 previousModel;
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 colorTint;
    float4 emissiveAdd;
    float4 params;
    float4 bounds;
};

struct LightData {
    float4 positionRange;
    float4 color;
    float4 direction;
    float4 extra;
};

struct MaterialUniforms {
    float4 baseColor;
    float4 emissive;
    float4 params;
    float4 params2;
    uint4 flags;
    float4 custom;
};

#define TEX_BASECOLOR 1u
#define TEX_NORMAL 2u
#define TEX_METALROUGH 4u
#define TEX_OCCLUSION 8u
#define TEX_EMISSIVE 16u

struct ProbeData {
    float4 center;
    float4 extents;
};

// Buffer / texture indices (see BufferIndex / TextureIndex in GPUTypes.swift).
#define BUF_VERTICES 0
#define BUF_SKIN 1
#define BUF_FRAME 2
#define BUF_INSTANCES 3
#define BUF_MATERIAL 4
#define BUF_LIGHTS 5
#define BUF_CLUSTER_COUNTS 6
#define BUF_CLUSTER_INDICES 7
#define BUF_JOINTS 8
#define BUF_INSTANCE_INDICES 9
#define BUF_PROBES 10
#define BUF_CASCADE 11

// Function constants select shader variants (see ShaderVariant in ShaderLibrary.swift).
constant bool HAS_SKINNING [[function_constant(0)]];
constant bool HAS_ALPHA_TEST [[function_constant(1)]];
constant bool HAS_VERTEX_COLOR [[function_constant(2)]];
constant bool USE_CLUSTERS [[function_constant(3)]];
constant bool IS_UNLIT [[function_constant(4)]];
constant bool HAS_SKINNING_V = is_function_constant_defined(HAS_SKINNING) && HAS_SKINNING;
constant bool HAS_ALPHA_TEST_V = is_function_constant_defined(HAS_ALPHA_TEST) && HAS_ALPHA_TEST;
constant bool HAS_VERTEX_COLOR_V = is_function_constant_defined(HAS_VERTEX_COLOR) && HAS_VERTEX_COLOR;
constant bool USE_CLUSTERS_V = !is_function_constant_defined(USE_CLUSTERS) || USE_CLUSTERS;
constant bool IS_UNLIT_V = is_function_constant_defined(IS_UNLIT) && IS_UNLIT;

// MARK: - Vertex input

struct MeshVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float4 tangent [[attribute(2)]];
    float2 uv0 [[attribute(3)]];
    float2 uv1 [[attribute(4)]];
    float4 color [[attribute(5)]];
    // Present only in skinned pipelines (the vertex descriptor adds buffer 1 for them).
    ushort4 joints [[attribute(6), function_constant(HAS_SKINNING)]];
    float4 weights [[attribute(7), function_constant(HAS_SKINNING)]];
};

// MARK: - Utilities

inline float3x3 normalMatrix(InstanceData inst) {
    return float3x3(inst.normal0.xyz, inst.normal1.xyz, inst.normal2.xyz);
}

inline float luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

inline float3 linearToSRGB(float3 c) {
    float3 lo = c * 12.92f;
    float3 hi = 1.055f * pow(max(c, 0.0f), 1.0f / 2.4f) - 0.055f;
    return select(hi, lo, c <= 0.0031308f);
}

inline float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92f;
    float3 hi = pow((c + 0.055f) / 1.055f, 2.4f);
    return select(hi, lo, c <= 0.04045f);
}

/// Reconstructs a world position from a depth-buffer value and screen UV.
inline float3 worldFromDepth(float2 uv, float depth, float4x4 inverseViewProjection) {
    float4 ndc = float4(uv.x * 2.0f - 1.0f, (1.0f - uv.y) * 2.0f - 1.0f, depth, 1.0f);
    float4 w = inverseViewProjection * ndc;
    return w.xyz / w.w;
}

/// Linear view depth (positive distance) from a reverse-Z perspective depth value.
inline float linearDepth(float depth, float4x4 inverseProjection) {
    float4 v = inverseProjection * float4(0.0f, 0.0f, depth, 1.0f);
    return -v.z / v.w;
}

/// Octahedral normal encoding for compact G-buffer/normal targets.
inline float2 octEncode(float3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    float2 e = n.z >= 0.0f ? n.xy : (1.0f - abs(n.yx)) * select(float2(-1.0f), float2(1.0f), n.xy >= 0.0f);
    return e * 0.5f + 0.5f;
}

inline float3 octDecode(float2 e) {
    e = e * 2.0f - 1.0f;
    float3 n = float3(e.x, e.y, 1.0f - abs(e.x) - abs(e.y));
    float t = saturate(-n.z);
    n.xy += select(float2(t), float2(-t), n.xy >= 0.0f);
    return normalize(n);
}

/// Interleaved gradient noise (Jimenez 2014) for dithering and sample rotation.
inline float interleavedGradientNoise(float2 p, float frame) {
    p += frame * 5.588238f;
    return fract(52.9829189f * fract(0.06711056f * p.x + 0.00583715f * p.y));
}

inline uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}

inline float random01(uint seed) { return float(hash(seed)) / 4294967295.0f; }

/// Builds an orthonormal basis around `n` (Frisvad / Duff et al. 2017).
inline void basis(float3 n, thread float3 &t, thread float3 &b) {
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z);
    float c = n.x * n.y * a;
    t = float3(1.0f + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

inline float3 cosineSampleHemisphere(float2 u, float3 n) {
    float r = sqrt(u.x);
    float phi = 2.0f * FEROX_PI * u.y;
    float3 t, b;
    basis(n, t, b);
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0f, 1.0f - u.x)));
}

inline float2 hammersley(uint i, uint n) {
    uint bits = reverse_bits(i);
    return float2(float(i) / float(n), float(bits) * 2.3283064365386963e-10f);
}

/// GGX importance sample of the half vector.
inline float3 importanceSampleGGX(float2 xi, float3 n, float roughness) {
    float a = roughness * roughness;
    float phi = 2.0f * FEROX_PI * xi.x;
    float cosTheta = sqrt((1.0f - xi.y) / (1.0f + (a * a - 1.0f) * xi.y));
    float sinTheta = sqrt(1.0f - cosTheta * cosTheta);
    float3 h = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    float3 t, b;
    basis(n, t, b);
    return normalize(t * h.x + b * h.y + n * h.z);
}

// MARK: - BRDF (metallic-roughness, glTF 2.0 appendix B)

inline float D_GGX(float NoH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0f) + 1.0f;
    return a2 / (FEROX_PI * d * d + 1e-7f);
}

inline float V_SmithGGXCorrelated(float NoV, float NoL, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0f - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0f - a2) + a2);
    return 0.5f / (gv + gl + 1e-7f);
}

inline float3 F_Schlick(float3 f0, float VoH) {
    float f = pow(1.0f - VoH, 5.0f);
    return f0 + (1.0f - f0) * f;
}

inline float3 F_SchlickRoughness(float3 f0, float NoV, float roughness) {
    return f0 + (max(float3(1.0f - roughness), f0) - f0) * pow(1.0f - NoV, 5.0f);
}

struct SurfaceData {
    float3 position;
    float3 normal;
    float3 view;
    float3 albedo;
    float metallic;
    float roughness;
    float occlusion;
    float3 emissive;
    float alpha;
};

/// Direct lighting from one light with direction `L` (towards light) and incoming radiance.
inline float3 shadeDirect(SurfaceData s, float3 L, float3 radiance) {
    float3 H = normalize(s.view + L);
    float NoL = saturate(dot(s.normal, L));
    if (NoL <= 0.0f) return float3(0.0f);
    float NoV = max(dot(s.normal, s.view), 1e-4f);
    float NoH = saturate(dot(s.normal, H));
    float VoH = saturate(dot(s.view, H));
    float3 f0 = mix(float3(0.04f), s.albedo, s.metallic);
    float3 F = F_Schlick(f0, VoH);
    float D = D_GGX(NoH, s.roughness);
    float V = V_SmithGGXCorrelated(NoV, NoL, s.roughness);
    float3 spec = D * V * F;
    float3 diffuse = (1.0f - F) * (1.0f - s.metallic) * s.albedo / FEROX_PI;
    return (diffuse + spec) * radiance * NoL;
}

/// Smooth distance attenuation (Karis 2013) for punctual lights.
inline float distanceAttenuation(float d2, float range) {
    float invR2 = 1.0f / max(range * range, 1e-4f);
    float f = saturate(1.0f - d2 * d2 * invR2 * invR2);
    return f * f / max(d2, 1e-4f);
}

inline float spotAttenuation(float3 L, float3 spotDir, float cosOuter, float cosInner) {
    float cd = dot(-L, spotDir);
    float t = saturate((cd - cosOuter) / max(cosInner - cosOuter, 1e-4f));
    return t * t;
}

// MARK: - Fullscreen triangle

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    FullscreenOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv = float2(p.x, 1.0f - p.y);
    return o;
}

// MARK: - Clustered lighting helpers

inline uint clusterIndex(float2 fragCoord, float viewDepth, constant FrameUniforms &f) {
    uint3 dims = f.clusterDims.xyz;
    uint cx = min(uint(fragCoord.x * f.viewport.z * float(dims.x)), dims.x - 1);
    uint cy = min(uint(fragCoord.y * f.viewport.w * float(dims.y)), dims.y - 1);
    float slice = log(max(viewDepth, 1e-3f)) * f.clusterParams.z - f.clusterParams.w;
    uint cz = min(uint(max(slice, 0.0f)), dims.z - 1);
    return cx + cy * dims.x + cz * dims.x * dims.y;
}
