// Ferox — mesh passes: shadow depth, depth/normal/motion prepass, and clustered forward PBR.

struct MeshOut {
    // `invariant` + `preserveInvariance` keep prepass and forward depths bit-identical.
    float4 position [[position, invariant]];
    float3 worldPosition;
    float3 normal;
    float4 tangent;
    float2 uv0;
    float4 color;
    float4 currentClip;
    float4 previousClip;
    uint instance [[flat]];
    // Draw slot (`instance_id`, including base instance). Indexes the material-id buffer.
    uint materialSlot [[flat]];
};

struct SkinResult {
    float4 position;
    float4 previous;
    float3 normal;
    float3 tangent;
};

/// Applies linear-blend skinning (joint palette per instance, offset in params.w).
inline SkinResult skin(MeshVertexIn v, constant float4x4 *joints, uint paletteOffset) {
    SkinResult r;
    float4 p = float4(v.position, 1.0f);
    if (HAS_SKINNING_V) {
        float4x4 m = joints[paletteOffset + v.joints.x] * v.weights.x
                   + joints[paletteOffset + v.joints.y] * v.weights.y
                   + joints[paletteOffset + v.joints.z] * v.weights.z
                   + joints[paletteOffset + v.joints.w] * v.weights.w;
        r.position = m * p;
        r.normal = (m * float4(v.normal, 0.0f)).xyz;
        r.tangent = (m * float4(v.tangent.xyz, 0.0f)).xyz;
    } else {
        r.position = p;
        r.normal = v.normal;
        r.tangent = v.tangent.xyz;
    }
    // Skinned previous-frame positions are approximated with the current pose (motion
    // vectors then capture object/camera motion but not intra-skeleton motion).
    r.previous = r.position;
    return r;
}

vertex MeshOut meshVertex(MeshVertexIn v [[stage_in]],
                          constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                          const device InstanceData *instances [[buffer(BUF_INSTANCES)]],
                          const device uint *instanceIndices [[buffer(BUF_INSTANCE_INDICES)]],
                          constant float4x4 *joints [[buffer(BUF_JOINTS), function_constant(HAS_SKINNING)]],
                          uint iid [[instance_id]]) {
    // Metal's instance_id already includes the draw's base instance, so it indexes the
    // batch's slice of `instanceIndices` directly.
    uint index = instanceIndices[iid];
    InstanceData inst = instances[index];
    SkinResult s;
    if (HAS_SKINNING_V) {
        s = skin(v, joints, uint(inst.params.w));
    } else {
        s.position = float4(v.position, 1.0f);
        s.previous = s.position;
        s.normal = v.normal;
        s.tangent = v.tangent.xyz;
    }
    float4 world = inst.model * s.position;
    float4 prevWorld = inst.previousModel * s.previous;
    MeshOut o;
    o.position = frame.viewProjection * world;
    o.worldPosition = world.xyz;
    float3x3 nm = normalMatrix(inst);
    o.normal = normalize(nm * s.normal);
    o.tangent = float4(normalize((inst.model * float4(s.tangent, 0.0f)).xyz), v.tangent.w);
    o.uv0 = v.uv0;
    o.color = HAS_VERTEX_COLOR_V ? v.color : float4(1.0f);
    o.color *= inst.colorTint;
    o.currentClip = frame.unjitteredViewProjection * world;
    o.previousClip = frame.previousUnjitteredViewProjection * prevWorld;
    o.instance = index;
    o.materialSlot = iid;
    return o;
}

/// Shadow-map vertex shader: the cascade matrix arrives in buffer BUF_CASCADE.
vertex MeshOut shadowVertex(MeshVertexIn v [[stage_in]],
                            constant float4x4 &lightViewProjection [[buffer(BUF_CASCADE)]],
                            const device InstanceData *instances [[buffer(BUF_INSTANCES)]],
                            const device uint *instanceIndices [[buffer(BUF_INSTANCE_INDICES)]],
                            constant float4x4 *joints [[buffer(BUF_JOINTS), function_constant(HAS_SKINNING)]],
                            uint iid [[instance_id]]) {
    uint index = instanceIndices[iid];  // instance_id includes the base instance
    InstanceData inst = instances[index];
    float4 p = float4(v.position, 1.0f);
    if (HAS_SKINNING_V) { p = skin(v, joints, uint(inst.params.w)).position; }
    MeshOut o;
    float4 world = inst.model * p;
    o.position = lightViewProjection * world;
    o.worldPosition = world.xyz;
    o.normal = float3(0.0f, 1.0f, 0.0f);
    o.tangent = float4(1.0f, 0.0f, 0.0f, 1.0f);
    o.uv0 = v.uv0;
    o.color = float4(1.0f);
    o.currentClip = o.position;
    o.previousClip = o.position;
    o.instance = index;
    o.materialSlot = iid;
    return o;
}

/// Alpha-tested shadow casters discard transparent texels; opaque casters use no fragment shader.
fragment void shadowAlphaTestFragment(MeshOut in [[stage_in]],
                                      constant MaterialUniforms &mat [[buffer(BUF_MATERIAL)]],
                                      texture2d<float> baseColorTex [[texture(0)]],
                                      sampler s [[sampler(0)]]) {
    float a = mat.baseColor.a;
    if ((mat.flags.x & TEX_BASECOLOR) != 0u) { a *= baseColorTex.sample(s, in.uv0).a; }
    if (a < mat.params2.x) { discard_fragment(); }
}

// MARK: - Surface reconstruction shared by prepass and forward

inline SurfaceData buildSurface(MeshOut in, bool frontFacing, constant MaterialUniforms &mat,
                                const device InstanceData &inst,
                                texture2d<float> baseColorTex, texture2d<float> normalTex,
                                texture2d<float> metalRoughTex, texture2d<float> occlusionTex,
                                texture2d<float> emissiveTex, sampler s, float3 cameraPos) {
    SurfaceData sd;
    float4 base = mat.baseColor * in.color;
    if ((mat.flags.x & TEX_BASECOLOR) != 0u) { base *= baseColorTex.sample(s, in.uv0); }
    sd.albedo = base.rgb;
    sd.alpha = base.a;
    float metallic = mat.params.x, roughness = mat.params.y;
    if ((mat.flags.x & TEX_METALROUGH) != 0u) {
        float4 mr = metalRoughTex.sample(s, in.uv0);
        roughness *= mr.g;
        metallic *= mr.b;
    }
    if (inst.params.x >= 0.0f) { metallic = inst.params.x; }
    if (inst.params.y >= 0.0f) { roughness = inst.params.y; }
    sd.metallic = saturate(metallic);
    sd.roughness = clamp(roughness, 0.045f, 1.0f);
    float3 n = normalize(in.normal);
    if (!frontFacing) { n = -n; }
    if ((mat.flags.x & TEX_NORMAL) != 0u) {
        float3 t = normalize(in.tangent.xyz - n * dot(n, in.tangent.xyz));
        float3 b = cross(n, t) * in.tangent.w;
        float3 tn = normalTex.sample(s, in.uv0).xyz * 2.0f - 1.0f;
        tn.xy *= mat.params.z;
        n = normalize(t * tn.x + b * tn.y + n * tn.z);
    }
    sd.normal = n;
    sd.occlusion = 1.0f;
    if ((mat.flags.x & TEX_OCCLUSION) != 0u) {
        sd.occlusion = mix(1.0f, occlusionTex.sample(s, in.uv0).r, mat.params.w);
    }
    sd.emissive = mat.emissive.rgb + inst.emissiveAdd.rgb;
    if ((mat.flags.x & TEX_EMISSIVE) != 0u) { sd.emissive *= emissiveTex.sample(s, in.uv0).rgb; }
    sd.position = in.worldPosition;
    sd.view = normalize(cameraPos - in.worldPosition);
    return sd;
}

// MARK: - Prepass (depth + normal/roughness + motion vectors)

struct PrepassOut {
    float4 normalRoughness [[color(0)]];
    float2 motion [[color(1)]];
};

fragment PrepassOut prepassFragment(MeshOut in [[stage_in]], bool frontFacing [[front_facing]],
                                    constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                    constant MaterialUniforms &matDiscrete [[buffer(BUF_MATERIAL), function_constant(USE_DISCRETE_MATERIALS)]],
                                    const device InstanceData *instances [[buffer(BUF_INSTANCES)]],
                                    texture2d<float> baseColorTex [[texture(0), function_constant(USE_DISCRETE_MATERIALS)]],
                                    texture2d<float> normalTex [[texture(1), function_constant(USE_DISCRETE_MATERIALS)]],
                                    texture2d<float> metalRoughTex [[texture(2), function_constant(USE_DISCRETE_MATERIALS)]],
                                    texture2d<float> occlusionTex [[texture(3), function_constant(USE_DISCRETE_MATERIALS)]],
                                    texture2d<float> emissiveTex [[texture(4), function_constant(USE_DISCRETE_MATERIALS)]],
                                    constant MaterialRecord *materials [[buffer(BUF_MATERIAL_TABLE), function_constant(USE_MATERIAL_ARGUMENTS)]],
                                    const device uint *materialIds [[buffer(BUF_MATERIAL_IDS), function_constant(USE_MATERIAL_ARGUMENTS)]],
                                    sampler s [[sampler(0)]]) {
    constant MaterialUniforms *matPtr;
    texture2d<float> bc;
    texture2d<float> nm;
    texture2d<float> mr;
    texture2d<float> oc;
    texture2d<float> em;
    if (USE_MATERIAL_ARGUMENTS_V) {
        MaterialRecord rec = materials[materialIds[in.materialSlot]];
        matPtr = rec.uniforms;
        bc = rec.baseColor;
        nm = rec.normalMap;
        mr = rec.metalRough;
        oc = rec.occlusion;
        em = rec.emissive;
    } else {
        matPtr = &matDiscrete;
        bc = baseColorTex;
        nm = normalTex;
        mr = metalRoughTex;
        oc = occlusionTex;
        em = emissiveTex;
    }
    constant MaterialUniforms &mat = *matPtr;
    SurfaceData sd = buildSurface(in, frontFacing, mat, instances[in.instance], bc, nm, mr, oc, em, s,
                                  frame.cameraPosition.xyz);
    if (HAS_ALPHA_TEST_V && sd.alpha < mat.params2.x) { discard_fragment(); }
    PrepassOut o;
    o.normalRoughness = float4(sd.normal * 0.5f + 0.5f, sd.roughness);
    // Motion in UV units (current − previous), from unjittered positions.
    float2 cur = in.currentClip.xy / in.currentClip.w;
    float2 prev = in.previousClip.xy / in.previousClip.w;
    o.motion = (cur - prev) * float2(0.5f, -0.5f);
    return o;
}

/// Optional picking target. Not attached to the default prepass pipeline: a caller that
/// wants instance ids builds a pipeline with this fragment and an `r32Uint` colour attachment.
/// The value is the index into `InstanceData` / `InstancePickMap` (`0xFFFFFFFF` is unused here;
/// a cleared attachment is the miss).
struct PickOut {
    uint instanceID [[color(0)]];
};

fragment PickOut prepassPickFragment(MeshOut in [[stage_in]]) {
    PickOut o;
    o.instanceID = in.instance;
    return o;
}

// MARK: - Forward PBR

/// Shadow-map visibility at `uvz` in slice `slice`: one unfiltered comparison when `hard`,
/// otherwise a 3 × 3 PCF kernel, widened by a blocker search when `pcss`.
inline float sampleShadow(depth2d_array<float> shadowMap, sampler cmp, float3 uvz, uint slice, float texel,
                          bool hard, bool pcss) {
    if (hard) {
        constexpr sampler hardCmp(filter::nearest, address::clamp_to_edge, compare_func::less);
        return shadowMap.sample_compare(hardCmp, uvz.xy, slice, uvz.z);
    }
    float radius = 1.0f;
    if (pcss) {
        // Blocker search (simplified PCSS): estimate penumbra from average occluder depth.
        constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);
        float blockers = 0.0f, count = 0.0f;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float d = shadowMap.sample(pointSampler, uvz.xy + float2(x, y) * texel * 2.0f, slice);
                if (d < uvz.z) { blockers += d; count += 1.0f; }
            }
        }
        if (count < 1.0f) { return 1.0f; }
        float avg = blockers / count;
        radius = clamp((uvz.z - avg) / max(avg, 1e-3f) * 40.0f, 1.0f, 6.0f);
    }
    float sum = 0.0f;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            sum += shadowMap.sample_compare(cmp, uvz.xy + float2(x, y) * texel * radius, slice, uvz.z);
        }
    }
    return sum / 9.0f;
}

inline float sunShadow(SurfaceData sd, constant FrameUniforms &frame, depth2d_array<float> shadowMap, sampler cmp, float viewDepth) {
    uint cascades = uint(frame.shadowParams.w);
    if (cascades == 0u || frame.sunColor.a < 0.5f) { return 1.0f; }
    uint c = 0u;
    for (uint i = 0u; i < cascades - 1u; i++) { if (viewDepth > frame.cascadeSplits[i]) { c = i + 1u; } }
    float3 L = normalize(frame.sunDirection.xyz);
    float3 p = sd.position + sd.normal * frame.shadowParams.y * (1.0f + float(c));
    float4 lp = frame.shadowMatrices[c] * float4(p, 1.0f);
    float3 uvz = float3(lp.xy / lp.w * float2(0.5f, -0.5f) + 0.5f, lp.z / lp.w);
    if (any(uvz.xy < 0.0f) || any(uvz.xy > 1.0f) || uvz.z > 1.0f) { return 1.0f; }
    float slope = 1.0f - saturate(dot(sd.normal, L));
    uvz.z -= frame.shadowParams.x * (1.0f + slope * 2.0f);
    bool hard = (frame.lightCounts.w & FRAME_FLAG_HARD) != 0u;
    bool pcss = (frame.lightCounts.w & FRAME_FLAG_PCSS) != 0u;
    return sampleShadow(shadowMap, cmp, uvz, c, frame.shadowParams.z, hard, pcss);
}

/// Point/spot shadow visibility. `l.extra.y` is the light's first slice in `localShadows`
/// (< 0: unshadowed); a point light owns six slices, one per cube face, chosen by the
/// dominant axis of the light-to-surface vector exactly as `LocalShadowPlanner.pointFace`.
/// The normal offset `l.extra.w` scales with distance because texels grow with it.
inline float localShadow(SurfaceData sd, LightData l, constant FrameUniforms &frame,
                         const device float4x4 *matrices, depth2d_array<float> localShadows, sampler cmp) {
    if (l.extra.y < 0.0f) { return 1.0f; }
    uint slice = uint(l.extra.y);
    float3 offset = sd.position - l.positionRange.xyz;
    if (l.color.w < 1.5f) {
        float3 a = abs(offset);
        uint face = (a.x >= a.y && a.x >= a.z) ? (offset.x >= 0.0f ? 0u : 1u)
                  : (a.y >= a.z) ? (offset.y >= 0.0f ? 2u : 3u)
                  : (offset.z >= 0.0f ? 4u : 5u);
        slice += face;
    }
    float3 p = sd.position + sd.normal * (l.extra.w * length(offset));
    float4 lp = matrices[slice] * float4(p, 1.0f);
    if (lp.w <= 0.0f) { return 1.0f; }
    float3 uvz = float3(lp.xy / lp.w * float2(0.5f, -0.5f) + 0.5f, lp.z / lp.w);
    if (any(uvz.xy < 0.0f) || any(uvz.xy > 1.0f) || uvz.z > 1.0f || uvz.z < 0.0f) { return 1.0f; }
    bool hard = (frame.lightCounts.w & FRAME_FLAG_HARD) != 0u;
    // PCSS is a sun-only effect; local lights fall back to PCF.
    return sampleShadow(localShadows, cmp, uvz, slice, l.extra.z, hard, false);
}

inline float3 evaluatePunctual(SurfaceData sd, LightData l, bool receives, constant FrameUniforms &frame,
                               const device float4x4 *matrices, depth2d_array<float> localShadows, sampler cmp) {
    float3 toLight = l.positionRange.xyz - sd.position;
    float d2 = dot(toLight, toLight);
    if (d2 > l.positionRange.w * l.positionRange.w) { return float3(0.0f); }
    float3 L = toLight * rsqrt(max(d2, 1e-8f));
    float att = distanceAttenuation(d2, l.positionRange.w);
    if (l.color.w > 1.5f) { att *= spotAttenuation(L, l.direction.xyz, l.direction.w, l.extra.x); }
    if (att <= 0.0f) { return float3(0.0f); }
    if (receives) { att *= localShadow(sd, l, frame, matrices, localShadows, cmp); }
    return shadeDirect(sd, L, l.color.rgb * att);
}

/// Box-projected reflection probe lookup; returns rgb and weight.
inline float4 sampleProbes(SurfaceData sd, float3 R, float lod, constant FrameUniforms &frame,
                           const device ProbeData *probes, texturecube_array<float> probeTex, sampler s) {
    uint count = frame.lightCounts.z;
    for (uint i = 0u; i < count; i++) {
        ProbeData p = probes[i];
        float3 local = sd.position - p.center.xyz;
        if (any(abs(local) > p.extents.xyz)) { continue; }
        // Box projection: intersect R with the probe box.
        float3 first = (p.extents.xyz - local) / R;
        float3 second = (-p.extents.xyz - local) / R;
        float3 furthest = max(first, second);
        float dist = min(min(furthest.x, furthest.y), furthest.z);
        float3 dir = local + R * dist;
        float3 edge = 1.0f - abs(local) / p.extents.xyz;
        float w = saturate(min(min(edge.x, edge.y), edge.z) / max(p.center.w, 1e-3f) * 4.0f);
        return float4(probeTex.sample(s, dir, uint(p.extents.w), level(lod)).rgb, w);
    }
    return float4(0.0f);
}

fragment float4 forwardFragment(MeshOut in [[stage_in]], bool frontFacing [[front_facing]],
                                constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                constant MaterialUniforms &matDiscrete [[buffer(BUF_MATERIAL), function_constant(USE_DISCRETE_MATERIALS)]],
                                const device InstanceData *instances [[buffer(BUF_INSTANCES)]],
                                const device LightData *lights [[buffer(BUF_LIGHTS)]],
                                const device uint *clusterCounts [[buffer(BUF_CLUSTER_COUNTS)]],
                                const device ushort *clusterIndices [[buffer(BUF_CLUSTER_INDICES)]],
                                const device ProbeData *probes [[buffer(BUF_PROBES)]],
                                const device float4x4 *localMatrices [[buffer(BUF_LOCAL_SHADOW_MATRICES)]],
                                texture2d<float> baseColorTex [[texture(0), function_constant(USE_DISCRETE_MATERIALS)]],
                                texture2d<float> normalTex [[texture(1), function_constant(USE_DISCRETE_MATERIALS)]],
                                texture2d<float> metalRoughTex [[texture(2), function_constant(USE_DISCRETE_MATERIALS)]],
                                texture2d<float> occlusionTex [[texture(3), function_constant(USE_DISCRETE_MATERIALS)]],
                                texture2d<float> emissiveTex [[texture(4), function_constant(USE_DISCRETE_MATERIALS)]],
                                constant MaterialRecord *materials [[buffer(BUF_MATERIAL_TABLE), function_constant(USE_MATERIAL_ARGUMENTS)]],
                                const device uint *materialIds [[buffer(BUF_MATERIAL_IDS), function_constant(USE_MATERIAL_ARGUMENTS)]],
                                texturecube<float> prefiltered [[texture(5)]],
                                texture2d<float> brdfLUT [[texture(6)]],
                                depth2d_array<float> shadowMap [[texture(7)]],
                                texture2d<float> rtShadow [[texture(8)]],
                                texture2d<float> rtReflection [[texture(9)]],
                                texture2d<float> aoTex [[texture(10)]],
                                texturecube<float> irradiance [[texture(11)]],
                                texturecube_array<float> probeTex [[texture(12)]],
                                depth2d_array<float> localShadows [[texture(13)]],
                                sampler s [[sampler(0)]],
                                sampler shadowCmp [[sampler(1)]]) {
    constexpr sampler linearClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constant MaterialUniforms *matPtr;
    texture2d<float> bc;
    texture2d<float> nm;
    texture2d<float> mr;
    texture2d<float> oc;
    texture2d<float> em;
    if (USE_MATERIAL_ARGUMENTS_V) {
        MaterialRecord rec = materials[materialIds[in.materialSlot]];
        matPtr = rec.uniforms;
        bc = rec.baseColor;
        nm = rec.normalMap;
        mr = rec.metalRough;
        oc = rec.occlusion;
        em = rec.emissive;
    } else {
        matPtr = &matDiscrete;
        bc = baseColorTex;
        nm = normalTex;
        mr = metalRoughTex;
        oc = occlusionTex;
        em = emissiveTex;
    }
    constant MaterialUniforms &mat = *matPtr;
    SurfaceData sd = buildSurface(in, frontFacing, mat, instances[in.instance], bc, nm, mr, oc, em, s,
                                  frame.cameraPosition.xyz);
    if (HAS_ALPHA_TEST_V && sd.alpha < mat.params2.x) { discard_fragment(); }
    if (IS_UNLIT_V) {
        // Same premultiplied convention as the lit path below.
        float a = mat.params2.y > 1.5f ? sd.alpha : 1.0f;
        return float4((sd.albedo + sd.emissive) * frame.exposure.x * a, a);
    }

    float2 screenUV = in.position.xy * frame.viewport.zw;
    float viewDepth = -(frame.view * float4(in.worldPosition, 1.0f)).z;
    float3 color = float3(0.0f);

    // MeshRenderer.receivesShadows == false sets emissiveAdd.w (see RenderSceneExtractor).
    bool receives = instances[in.instance].emissiveAdd.w < 0.5f;

    // Sun (directional light 0) with CSM or ray-traced visibility.
    if (frame.sunDirection.w > 0.0f) {
        float shadow = !receives ? 1.0f
                     : frame.effectFlags.x > 0.5f ? rtShadow.sample(linearClamp, screenUV).r
                                                  : sunShadow(sd, frame, shadowMap, shadowCmp, viewDepth);
        color += shadeDirect(sd, normalize(frame.sunDirection.xyz), frame.sunColor.rgb * frame.sunDirection.w) * shadow;
    }
    // Additional directional lights (indices [0, dirCount)) — light 0 is the sun when present.
    uint dirCount = frame.lightCounts.y;
    for (uint i = frame.sunDirection.w > 0.0f ? 1u : 0u; i < dirCount; i++) {
        color += shadeDirect(sd, -normalize(lights[i].direction.xyz), lights[i].color.rgb);
    }
    // Punctual lights: clustered lookup or brute force.
    if (USE_CLUSTERS_V) {
        uint ci = clusterIndex(in.position.xy, viewDepth, frame);
        uint n = min(clusterCounts[ci], frame.clusterDims.w);
        for (uint k = 0u; k < n; k++) {
            color += evaluatePunctual(sd, lights[clusterIndices[ci * frame.clusterDims.w + k]], receives, frame,
                                      localMatrices, localShadows, shadowCmp);
        }
    } else {
        uint total = dirCount + frame.lightCounts.x;
        for (uint i = dirCount; i < total; i++) {
            color += evaluatePunctual(sd, lights[i], receives, frame, localMatrices, localShadows, shadowCmp);
        }
    }

    // Image-based lighting (split-sum) with optional probe / ray-traced reflections.
    float NoV = max(dot(sd.normal, sd.view), 1e-4f);
    float3 f0 = mix(float3(0.04f), sd.albedo, sd.metallic);
    float3 F = F_SchlickRoughness(f0, NoV, sd.roughness);
    float3 kd = (1.0f - F) * (1.0f - sd.metallic);
    float3 diffuseIBL = irradiance.sample(linearClamp, sd.normal).rgb * sd.albedo * kd;
    float3 R = reflect(-sd.view, sd.normal);
    float mipCount = max(frame.exposure.z, 1.0f);
    float lod = sd.roughness * (mipCount - 1.0f);
    float3 specEnv = prefiltered.sample(linearClamp, R, level(lod)).rgb;
    float4 probe = sampleProbes(sd, R, lod, frame, probes, probeTex, linearClamp);
    specEnv = mix(specEnv, probe.rgb, probe.a);
    if (frame.effectFlags.z > 0.5f) {
        float4 rr = rtReflection.sample(linearClamp, screenUV);
        specEnv = mix(specEnv, rr.rgb, rr.a);
    }
    float2 brdf = brdfLUT.sample(linearClamp, float2(NoV, sd.roughness)).rg;
    float3 specularIBL = specEnv * (F * brdf.x + brdf.y);
    float ao = sd.occlusion;
    if (frame.effectFlags.y > 0.5f || frame.effectFlags.w > 0.5f) { ao *= aoTex.sample(linearClamp, screenUV).r; }
    color += (diffuseIBL + specularIBL) * frame.ambient.a * ao;
    color += frame.ambient.rgb * sd.albedo * ao;
    color += sd.emissive;

    // Exponential height-less fog.
    if (frame.fog.a > 0.0f) {
        float f = 1.0f - exp(-frame.fog.a * viewDepth);
        color = mix(color, frame.fog.rgb, saturate(f));
    }
    float alpha = mat.params2.y > 1.5f ? sd.alpha : 1.0f;
    // Output premultiplied for transparent blending.
    return float4(color * frame.exposure.x * alpha, alpha);
}
