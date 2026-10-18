// Ferox — clustered light assignment (Forward+).
//
// The view frustum is divided into dims.x × dims.y screen tiles and dims.z exponential
// depth slices. One thread per cluster builds the cluster's view-space AABB and tests
// every punctual light's bounding sphere, writing up to `clusterDims.w` indices.

inline float3 viewRay(float2 ndc, constant FrameUniforms &f) {
    float4 v = f.inverseProjection * float4(ndc, 1.0f, 1.0f);  // reverse-Z: z = 1 is the near plane
    float3 p = v.xyz / v.w;
    return p / -p.z;  // point at view depth 1
}

kernel void assignLights(constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                         const device LightData *lights [[buffer(BUF_LIGHTS)]],
                         device uint *clusterCounts [[buffer(BUF_CLUSTER_COUNTS)]],
                         device ushort *clusterIndices [[buffer(BUF_CLUSTER_INDICES)]],
                         uint gid [[thread_position_in_grid]]) {
    uint3 dims = frame.clusterDims.xyz;
    uint total = dims.x * dims.y * dims.z;
    if (gid >= total) { return; }
    uint cx = gid % dims.x;
    uint cy = (gid / dims.x) % dims.y;
    uint cz = gid / (dims.x * dims.y);

    float nearZ = frame.clusterParams.x, farZ = frame.clusterParams.y;
    float zNear = nearZ * pow(farZ / nearZ, float(cz) / float(dims.z));
    float zFar = nearZ * pow(farZ / nearZ, float(cz + 1u) / float(dims.z));

    // Tile corners in NDC (y up; tile 0 is the top row of the screen).
    float2 t0 = float2(float(cx) / float(dims.x), float(cy) / float(dims.y));
    float2 t1 = float2(float(cx + 1u) / float(dims.x), float(cy + 1u) / float(dims.y));
    float2 ndc0 = float2(t0.x * 2.0f - 1.0f, 1.0f - t1.y * 2.0f);
    float2 ndc1 = float2(t1.x * 2.0f - 1.0f, 1.0f - t0.y * 2.0f);

    float3 corners[4] = { viewRay(ndc0, frame), viewRay(float2(ndc1.x, ndc0.y), frame),
                          viewRay(float2(ndc0.x, ndc1.y), frame), viewRay(ndc1, frame) };
    float3 bmin = float3(1e30f), bmax = float3(-1e30f);
    for (int i = 0; i < 4; i++) {
        float3 a = corners[i] * zNear, b = corners[i] * zFar;
        bmin = min(bmin, min(a, b));
        bmax = max(bmax, max(a, b));
    }

    uint maxPerCluster = frame.clusterDims.w;
    uint first = frame.lightCounts.y;  // directional lights come first and are not clustered
    uint last = first + frame.lightCounts.x;
    uint count = 0u;
    for (uint li = first; li < last && count < maxPerCluster; li++) {
        LightData l = lights[li];
        float3 c = (frame.view * float4(l.positionRange.xyz, 1.0f)).xyz;
        float r = l.positionRange.w;
        float3 closest = clamp(c, bmin, bmax);
        float3 d = closest - c;
        if (dot(d, d) <= r * r) {
            clusterIndices[gid * maxPerCluster + count] = ushort(li);
            count++;
        }
    }
    clusterCounts[gid] = count;
}
