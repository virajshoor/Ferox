// Ferox — GPU-driven culling.
//
// 1. `hizCopy` + `hizDownsample` build a hierarchical-Z pyramid from last frame's depth.
//    With reverse-Z the *farthest* depth is the minimum, so each texel keeps the MIN of
//    its footprint (odd sizes fold in the extra row/column so nothing is skipped).
// 2. `resetDrawArgs` zeroes each batch's instance count.
// 3. `cullInstances` writes one visibility flag per instance (frustum, then optional Hi-Z).
// 4. `expandVisibleDraws` appends each visible instance to every opaque batch that draws
//    it, so a mesh with several submeshes is culled once and drawn in each batch.
//    The vertex shader reads `instanceIndices[instance_id]` (Metal's instance_id already
//    includes baseInstance).
//
// Hi-Z testing uses the previous frame's depth, so an object revealed by fast camera
// motion can be culled for one frame. The CPU path is used where this is unacceptable.

struct CullUniforms {
    float4 planes[6];           // world-space frustum planes (xyz normal pointing inwards, w distance)
    float4x4 previousViewProjection;
    float4 hizSize;             // xy mip-0 size, z mip count, w unused
    uint4 counts;               // x instance count, y flags (bit 0: occlusion), z batch count, w membership count
};

#define CULL_FLAG_OCCLUSION 1u
// Eight uints: five draw-argument words plus padding so each batch is 16-byte aligned.
#define DRAW_ARGS_STRIDE 8u

kernel void hizCopy(depth2d<float, access::read> depth [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    dst.write(float4(depth.read(gid)), gid);
}

/// `src` is a view of mip N-1 and `dst` a view of mip N.
kernel void hizDownsample(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint dw = dst.get_width(), dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) { return; }
    uint sw = src.get_width(), sh = src.get_height();
    uint2 base = gid * 2u;
    uint2 maxP = uint2(sw - 1u, sh - 1u);
    float m = src.read(min(base, maxP)).r;
    m = min(m, src.read(min(base + uint2(1, 0), maxP)).r);
    m = min(m, src.read(min(base + uint2(0, 1), maxP)).r);
    m = min(m, src.read(min(base + uint2(1, 1), maxP)).r);
    bool oddX = (sw & 1u) != 0u && gid.x == dw - 1u;
    bool oddY = (sh & 1u) != 0u && gid.y == dh - 1u;
    if (oddX) {
        m = min(m, src.read(min(base + uint2(2, 0), maxP)).r);
        m = min(m, src.read(min(base + uint2(2, 1), maxP)).r);
    }
    if (oddY) {
        m = min(m, src.read(min(base + uint2(0, 2), maxP)).r);
        m = min(m, src.read(min(base + uint2(1, 2), maxP)).r);
    }
    if (oddX && oddY) { m = min(m, src.read(min(base + uint2(2, 2), maxP)).r); }
    dst.write(float4(m), gid);
}

kernel void resetDrawArgs(device atomic_uint *args [[buffer(0)]],
                          constant CullUniforms &u [[buffer(1)]],
                          uint gid [[thread_position_in_grid]]) {
    if (gid >= u.counts.z) { return; }
    atomic_store_explicit(&args[gid * DRAW_ARGS_STRIDE + 1u], 0u, memory_order_relaxed);
}

inline bool sphereInFrustum(float4 sphere, constant CullUniforms &u) {
    for (int i = 0; i < 6; i++) {
        if (dot(u.planes[i].xyz, sphere.xyz) + u.planes[i].w < -sphere.w) { return false; }
    }
    return true;
}

/// Conservative occlusion test of a bounding sphere against the Hi-Z pyramid.
inline bool sphereVisibleHiZ(float4 sphere, constant CullUniforms &u, texture2d<float, access::read> hiz) {
    float2 uvMin = float2(1.0f), uvMax = float2(0.0f);
    float nearestDepth = 0.0f;  // reverse-Z: larger is nearer
    for (uint i = 0; i < 8u; i++) {
        float3 corner = sphere.xyz + float3((i & 1u) ? sphere.w : -sphere.w,
                                            (i & 2u) ? sphere.w : -sphere.w,
                                            (i & 4u) ? sphere.w : -sphere.w);
        float4 clip = u.previousViewProjection * float4(corner, 1.0f);
        if (clip.w <= 1e-4f) { return true; }  // crosses the near plane
        float3 ndc = clip.xyz / clip.w;
        float2 uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
        uvMin = min(uvMin, uv);
        uvMax = max(uvMax, uv);
        nearestDepth = max(nearestDepth, ndc.z);
    }
    if (uvMax.x < 0.0f || uvMax.y < 0.0f || uvMin.x > 1.0f || uvMin.y > 1.0f) { return true; }
    uvMin = saturate(uvMin);
    uvMax = saturate(uvMax);
    float2 extent = (uvMax - uvMin) * u.hizSize.xy;
    float mip = clamp(ceil(log2(max(max(extent.x, extent.y), 1.0f))), 0.0f, u.hizSize.z - 1.0f);
    uint lod = uint(mip);
    uint w = max(hiz.get_width(lod), 1u), h = max(hiz.get_height(lod), 1u);
    uint2 maxP = uint2(w - 1u, h - 1u);
    uint2 p0 = min(uint2(uvMin * float2(w, h)), maxP);
    uint2 p1 = min(uint2(uvMax * float2(w, h)), maxP);
    float farthest = min(min(hiz.read(p0, lod).r, hiz.read(uint2(p1.x, p0.y), lod).r),
                         min(hiz.read(uint2(p0.x, p1.y), lod).r, hiz.read(p1, lod).r));
    return nearestDepth >= farthest;
}

kernel void cullInstances(constant CullUniforms &u [[buffer(0)]],
                          const device InstanceData *instances [[buffer(1)]],
                          device uint *visibility [[buffer(2)]],
                          texture2d<float, access::read> hiz [[texture(0)]],
                          uint gid [[thread_position_in_grid]]) {
    if (gid >= u.counts.x) { return; }
    uint visible = 1u;
    float4 sphere = instances[gid].bounds;
    if (!sphereInFrustum(sphere, u)) {
        visible = 0u;
    } else if ((u.counts.y & CULL_FLAG_OCCLUSION) != 0u && !sphereVisibleHiZ(sphere, u, hiz)) {
        visible = 0u;
    }
    visibility[gid] = visible;
}

/// One thread per (instance, batch) membership. Visible instances are appended to that
/// batch's indirect arguments. `counts.w` is the membership count.
kernel void expandVisibleDraws(constant CullUniforms &u [[buffer(0)]],
                               const device uint *visibility [[buffer(1)]],
                               const device uint2 *memberships [[buffer(2)]],
                               device atomic_uint *args [[buffer(3)]],
                               device uint *instanceIndices [[buffer(4)]],
                               uint gid [[thread_position_in_grid]]) {
    if (gid >= u.counts.w) { return; }
    uint2 m = memberships[gid];
    if (m.x >= u.counts.x || visibility[m.x] == 0u) { return; }
    uint batch = m.y;
    if (batch >= u.counts.z) { return; }
    uint slot = atomic_fetch_add_explicit(&args[batch * DRAW_ARGS_STRIDE + 1u], 1u, memory_order_relaxed);
    uint base = atomic_load_explicit(&args[batch * DRAW_ARGS_STRIDE + 4u], memory_order_relaxed);
    instanceIndices[base + slot] = m.x;
}
