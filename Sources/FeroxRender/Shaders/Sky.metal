// Ferox — sky rendering and image-based-lighting precomputation.
//
// Environment pipeline (see IBLGenerator.swift):
//   procedural sky / equirect HDR / flat colour → environment cube (rgba16f, mipmapped)
//   environment cube → irradiance cube (diffuse, cosine convolution)
//   environment cube → prefiltered cube (GGX, one roughness per mip)
//   BRDF integration LUT (rg16f, computed once)

struct SkyParams {
    float4 sunDirection;  // xyz towards the sun, w turbidity
    float4 groundColor;   // rgb linear, a sun disc angular radius (radians)
    float4 tint;          // rgb flat colour (mode 2), a overall scale
    uint4 mode;           // x: 0 procedural, 1 equirect, 2 colour; y face size; z sample count; w mip
    float4 filter;        // x roughness (prefilter), y source resolution, zw unused
};

/// Direction through texel `uv` (0…1, y down) of cube face `face` (Metal / D3D convention).
inline float3 cubeDirection(uint face, float2 uv) {
    float2 c = uv * 2.0f - 1.0f;
    float3 d;
    switch (face) {
        case 0: d = float3(1.0f, -c.y, -c.x); break;
        case 1: d = float3(-1.0f, -c.y, c.x); break;
        case 2: d = float3(c.x, 1.0f, c.y); break;
        case 3: d = float3(c.x, -1.0f, -c.y); break;
        case 4: d = float3(c.x, -c.y, 1.0f); break;
        default: d = float3(-c.x, -c.y, -1.0f); break;
    }
    return normalize(d);
}

// MARK: - Preetham, Shirley & Smits (1999) analytic daylight

struct PerezCoefficients { float A, B, C, D, E; };

inline float perezF(float cosTheta, float gamma, float cosGamma, PerezCoefficients p) {
    return (1.0f + p.A * exp(p.B / max(cosTheta, 0.01f))) * (1.0f + p.C * exp(p.D * gamma) + p.E * cosGamma * cosGamma);
}

inline float3 preethamSky(float3 dir, float3 sun, float turbidity) {
    float T = clamp(turbidity, 1.7f, 10.0f);
    float thetaS = acos(clamp(sun.y, 0.0f, 1.0f));
    float cosTheta = max(dir.y, 0.0f);
    float cosGamma = clamp(dot(dir, sun), -1.0f, 1.0f);
    float gamma = acos(cosGamma);

    PerezCoefficients cY = { 0.1787f * T - 1.4630f, -0.3554f * T + 0.4275f, -0.0227f * T + 5.3251f,
                             0.1206f * T - 2.5771f, -0.0670f * T + 0.3703f };
    PerezCoefficients cx = { -0.0193f * T - 0.2592f, -0.0665f * T + 0.0008f, -0.0004f * T + 0.2125f,
                             -0.0641f * T - 0.8989f, -0.0033f * T + 0.0452f };
    PerezCoefficients cy = { -0.0167f * T - 0.2608f, -0.0950f * T + 0.0092f, -0.0079f * T + 0.2102f,
                             -0.0441f * T - 1.6537f, -0.0109f * T + 0.0529f };

    float chi = (4.0f / 9.0f - T / 120.0f) * (FEROX_PI - 2.0f * thetaS);
    float Yz = (4.0453f * T - 4.9710f) * tan(chi) - 0.2155f * T + 2.4192f;
    float t2 = thetaS * thetaS, t3 = t2 * thetaS;
    float xz = T * T * (0.00166f * t3 - 0.00375f * t2 + 0.00209f * thetaS)
             + T * (-0.02903f * t3 + 0.06377f * t2 - 0.03202f * thetaS + 0.00394f)
             + (0.11693f * t3 - 0.21196f * t2 + 0.06052f * thetaS + 0.25886f);
    float yz = T * T * (0.00275f * t3 - 0.00610f * t2 + 0.00317f * thetaS)
             + T * (-0.04214f * t3 + 0.08970f * t2 - 0.04153f * thetaS + 0.00516f)
             + (0.15346f * t3 - 0.26756f * t2 + 0.06670f * thetaS + 0.26688f);

    float cosThetaS = cos(thetaS);
    float Y = Yz * perezF(cosTheta, gamma, cosGamma, cY) / perezF(1.0f, thetaS, cosThetaS, cY);
    float x = xz * perezF(cosTheta, gamma, cosGamma, cx) / perezF(1.0f, thetaS, cosThetaS, cx);
    float y = yz * perezF(cosTheta, gamma, cosGamma, cy) / perezF(1.0f, thetaS, cosThetaS, cy);

    // xyY → XYZ → linear sRGB (Y is in kcd/m²; scaled to a comfortable range).
    Y = max(Y, 0.0f) * 0.06f;
    float X = x / max(y, 1e-4f) * Y;
    float Z = (1.0f - x - y) / max(y, 1e-4f) * Y;
    float3 rgb = float3(3.2406f * X - 1.5372f * Y - 0.4986f * Z,
                        -0.9689f * X + 1.8758f * Y + 0.0415f * Z,
                        0.0557f * X - 0.2040f * Y + 1.0570f * Z);
    return max(rgb, 0.0f);
}

inline float3 proceduralSky(float3 dir, constant SkyParams &p) {
    float3 sun = normalize(p.sunDirection.xyz);
    float3 sky = preethamSky(float3(dir.x, max(dir.y, 0.0f), dir.z), sun, p.sunDirection.w);
    // Ground: blend from horizon colour into the ground albedo lit by the sun.
    float3 horizon = preethamSky(normalize(float3(dir.x, 0.001f, dir.z)), sun, p.sunDirection.w);
    float3 ground = p.groundColor.rgb * saturate(sun.y + 0.1f) * 0.6f;
    float g = smoothstep(0.0f, -0.08f, dir.y);
    float3 c = dir.y >= 0.0f ? sky : mix(horizon, ground, g);
    // Sun disc with limb darkening (only above the horizon).
    float radius = max(p.groundColor.a, 1e-4f);
    float cosA = dot(dir, sun);
    float disc = smoothstep(cos(radius * 1.15f), cos(radius), cosA);
    if (disc > 0.0f && dir.y > -0.01f) {
        float mu = saturate(acos(clamp(cosA, -1.0f, 1.0f)) / radius);
        float limb = 1.0f - 0.6f * (1.0f - sqrt(max(1.0f - mu * mu, 0.0f)));
        c += float3(1.0f, 0.95f, 0.88f) * 60.0f * disc * limb * saturate(sun.y * 4.0f + 0.2f);
    }
    return c * p.tint.a;
}

inline float2 equirectUV(float3 d) {
    return float2(atan2(d.x, -d.z) / (2.0f * FEROX_PI) + 0.5f, acos(clamp(d.y, -1.0f, 1.0f)) / FEROX_PI);
}

/// Fills the environment cube from the procedural sky, an equirectangular map or a colour.
kernel void generateEnvironment(constant SkyParams &p [[buffer(0)]],
                                texture2d<float> equirect [[texture(0)]],
                                texturecube<float, access::write> outCube [[texture(1)]],
                                uint3 gid [[thread_position_in_grid]]) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) { return; }
    float3 dir = cubeDirection(gid.z, (float2(gid.xy) + 0.5f) / float(size));
    float3 c;
    if (p.mode.x == 0u) {
        c = proceduralSky(dir, p);
    } else if (p.mode.x == 1u) {
        constexpr sampler s(filter::linear, address::repeat);
        c = equirect.sample(s, equirectUV(dir), level(0.0f)).rgb * p.tint.a;
    } else {
        c = p.tint.rgb * p.tint.a;
    }
    // Clamp extreme values so the prefilter does not produce fireflies.
    outCube.write(float4(min(c, float3(64000.0f)), 1.0f), gid.xy, gid.z);
}

/// Diffuse irradiance: cosine-weighted hemisphere integral, sampled from low mips of the
/// environment to keep the sample count small.
kernel void convolveIrradiance(constant SkyParams &p [[buffer(0)]],
                               texturecube<float> env [[texture(0)]],
                               texturecube<float, access::write> outCube [[texture(1)]],
                               uint3 gid [[thread_position_in_grid]]) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) { return; }
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 n = cubeDirection(gid.z, (float2(gid.xy) + 0.5f) / float(size));
    uint count = max(p.mode.z, 64u);
    float3 sum = float3(0.0f);
    float srcSize = max(p.filter.y, 1.0f);
    // Solid angle per sample vs per source texel → mip level (Křivánek & Colbert 2008).
    float texelSolidAngle = 4.0f * FEROX_PI / (6.0f * srcSize * srcSize);
    for (uint i = 0u; i < count; i++) {
        float2 u = hammersley(i, count);
        float3 l = cosineSampleHemisphere(u, n);
        float pdf = max(dot(n, l), 1e-3f) / FEROX_PI;
        float sampleSolidAngle = 1.0f / (float(count) * pdf);
        float lod = max(0.5f * log2(sampleSolidAngle / texelSolidAngle) + 1.0f, 0.0f);
        sum += env.sample(s, l, level(lod)).rgb;
    }
    // Cosine-weighted sampling: E = π · mean(L); stored pre-divided by π for Lambert albedo.
    outCube.write(float4(sum / float(count), 1.0f), gid.xy, gid.z);
}

/// GGX specular prefilter for one mip (`filter.x` = roughness). Written into a texture view
/// of the destination mip; samples the source environment with PDF-based mip selection.
kernel void prefilterSpecular(constant SkyParams &p [[buffer(0)]],
                              texturecube<float> env [[texture(0)]],
                              texturecube<float, access::write> outCube [[texture(1)]],
                              uint3 gid [[thread_position_in_grid]]) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) { return; }
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 n = cubeDirection(gid.z, (float2(gid.xy) + 0.5f) / float(size));
    float roughness = p.filter.x;
    if (roughness < 0.02f) {
        outCube.write(float4(env.sample(s, n, level(0.0f)).rgb, 1.0f), gid.xy, gid.z);
        return;
    }
    float3 v = n;
    uint count = max(p.mode.z, 32u);
    float srcSize = max(p.filter.y, 1.0f);
    float texelSolidAngle = 4.0f * FEROX_PI / (6.0f * srcSize * srcSize);
    float3 sum = float3(0.0f);
    float weight = 0.0f;
    for (uint i = 0u; i < count; i++) {
        float3 h = importanceSampleGGX(hammersley(i, count), n, roughness);
        float3 l = normalize(2.0f * dot(v, h) * h - v);
        float NoL = dot(n, l);
        if (NoL <= 0.0f) { continue; }
        float NoH = saturate(dot(n, h));
        float pdf = D_GGX(NoH, roughness) * 0.25f + 1e-4f;  // NoH / (4 VoH) with V = N
        float sampleSolidAngle = 1.0f / (float(count) * pdf);
        float lod = max(0.5f * log2(sampleSolidAngle / texelSolidAngle) + 1.0f, 0.0f);
        sum += env.sample(s, l, level(lod)).rgb * NoL;
        weight += NoL;
    }
    outCube.write(float4(sum / max(weight, 1e-4f), 1.0f), gid.xy, gid.z);
}

/// Split-sum BRDF integration (Karis 2013): r = scale, g = bias for F0.
kernel void integrateBRDF(texture2d<float, access::write> lut [[texture(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint w = lut.get_width(), h = lut.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float NoV = max((float(gid.x) + 0.5f) / float(w), 1e-3f);
    float roughness = (float(gid.y) + 0.5f) / float(h);
    float3 v = float3(sqrt(1.0f - NoV * NoV), 0.0f, NoV);
    float3 n = float3(0.0f, 0.0f, 1.0f);
    float a = 0.0f, b = 0.0f;
    const uint count = 256u;
    for (uint i = 0u; i < count; i++) {
        float3 hv = importanceSampleGGX(hammersley(i, count), n, roughness);
        float3 l = normalize(2.0f * dot(v, hv) * hv - v);
        float NoL = saturate(l.z);
        float NoH = saturate(hv.z);
        float VoH = saturate(dot(v, hv));
        if (NoL > 0.0f) {
            // V_SmithGGXCorrelated already includes the 1/(4 NoL NoV) term.
            float vis = V_SmithGGXCorrelated(NoV, NoL, roughness) * 4.0f * NoL * VoH / max(NoH, 1e-4f);
            float fc = pow(1.0f - VoH, 5.0f);
            a += (1.0f - fc) * vis;
            b += fc * vis;
        }
    }
    lut.write(float4(a / float(count), b / float(count), 0.0f, 1.0f), gid);
}

// MARK: - Sky pass

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

/// Fullscreen triangle at the far plane (depth 0 with reverse-Z).
vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
    SkyOut o;
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0f - 1.0f;
    o.position = float4(p, 0.0f, 1.0f);
    o.ndc = p;
    return o;
}

fragment float4 skyFragment(SkyOut in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                            texturecube<float> env [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // Use a point slightly in front of the far plane: reverse-Z far = 0 maps to infinity.
    float4 w = frame.inverseViewProjection * float4(in.ndc, 1e-4f, 1.0f);
    float3 dir = normalize(w.xyz / w.w - frame.cameraPosition.xyz);
    float3 c = env.sample(s, dir, level(0.0f)).rgb * frame.exposure.w;
    if (frame.fog.a > 0.0f) {
        // Fog the horizon band so distant geometry blends into the sky.
        float horizon = 1.0f - saturate(abs(dir.y) * 4.0f);
        c = mix(c, frame.fog.rgb, horizon * saturate(frame.fog.a * 50.0f));
    }
    return float4(c * frame.exposure.x, 1.0f);
}
