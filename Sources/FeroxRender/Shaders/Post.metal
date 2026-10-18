// Ferox — post-processing: SSAO, TAA / temporal upscaling, bloom, depth of field, motion
// blur, auto exposure, tone mapping and grading, FXAA, SMAA-style morphological AA,
// contrast-adaptive sharpening and the Ferox spatial upscaler.
//
// Fragment passes use `fullscreenVertex` (Common.metal). `PostUniforms` mirrors
// GPUTypes.swift; it is bound at buffer(0), FrameUniforms at BUF_FRAME.

struct PostUniforms {
    float4 bloom;       // x threshold, y soft knee, z intensity, w upsample radius
    float4 tonemap;     // x operator (0 none, 1 Reinhard, 2 ACES fit, 3 AgX), y exposure multiplier, z contrast, w saturation
    float4 whiteBalance;// xyz LMS scale (computed on the CPU from temperature / tint), w vignette
    float4 lift;        // rgb lift, a auto-exposure enabled
    float4 gamma;       // rgb gamma, a dither strength
    float4 gain;        // rgb gain, a unused
    float4 dof;         // x focus distance (m), y f-number, z focal length (m), w max CoC (px)
    float4 motionBlur;  // x shutter fraction, y sample count, z max length (px), w unused
    float4 taa;         // x history weight (feedback), y unused, z sharpness, w reset (1 = discard history)
    float4 sharpen;     // x amount (0…1)
    float4 ssao;        // x radius (m), y intensity, z bias, w sample count
    float4 sizes;       // xy source size, zw destination size (pixels)
    float4 texel;       // xy 1/source size, zw 1/destination size
    float4 misc;        // x frame index, y delta time, z exposure adaptation speed, w mip / pass index
};

constexpr sampler pointClamp(filter::nearest, address::clamp_to_edge);
constexpr sampler linearClampS(filter::linear, address::clamp_to_edge);

// MARK: - Screen-space ambient occlusion (normal-oriented hemisphere, view space)

inline float3 viewPositionFromDepth(float2 uv, float depth, constant FrameUniforms &f) {
    float4 ndc = float4(uv.x * 2.0f - 1.0f, (1.0f - uv.y) * 2.0f - 1.0f, depth, 1.0f);
    float4 v = f.inverseProjection * ndc;
    return v.xyz / v.w;
}

fragment float4 ssaoFragment(FullscreenOut in [[stage_in]],
                             constant PostUniforms &post [[buffer(0)]],
                             constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                             depth2d<float> depthTex [[texture(0)]],
                             texture2d<float> normalTex [[texture(1)]]) {
    float depth = depthTex.sample(pointClamp, in.uv);
    if (depth <= 0.0f) { return float4(1.0f); }  // sky (reverse-Z far plane)
    float3 p = viewPositionFromDepth(in.uv, depth, frame);
    float3 nWorld = normalize(normalTex.sample(pointClamp, in.uv).xyz * 2.0f - 1.0f);
    float3 n = normalize((frame.view * float4(nWorld, 0.0f)).xyz);
    float radius = post.ssao.x;
    uint count = clamp(uint(post.ssao.w), 4u, 64u);
    float noise = interleavedGradientNoise(in.position.xy, post.misc.x);
    float occlusion = 0.0f;
    for (uint i = 0u; i < count; i++) {
        float2 u = hammersley(i, count);
        u.y = fract(u.y + noise);
        float3 dir = cosineSampleHemisphere(u, n);
        // Distribute samples towards the centre (more detail near the surface).
        float scale = float(i + 1u) / float(count);
        scale = mix(0.1f, 1.0f, scale * scale);
        float3 s = p + dir * radius * scale;
        float4 clip = frame.projection * float4(s, 1.0f);
        float2 suv = clip.xy / clip.w * float2(0.5f, -0.5f) + 0.5f;
        if (any(suv < 0.0f) || any(suv > 1.0f)) { continue; }
        float sceneDepth = depthTex.sample(pointClamp, suv);
        float sceneZ = viewPositionFromDepth(suv, sceneDepth, frame).z;
        // View space looks down -Z: an occluder is closer to the camera (greater z).
        float rangeCheck = smoothstep(0.0f, 1.0f, radius / max(abs(p.z - sceneZ), 1e-4f));
        occlusion += (sceneZ >= s.z + post.ssao.z ? 1.0f : 0.0f) * rangeCheck;
    }
    float ao = 1.0f - occlusion / float(count);
    return float4(pow(saturate(ao), max(post.ssao.y, 0.01f)));
}

/// Depth-aware 5×5 blur of the raw SSAO term.
fragment float4 ssaoBlurFragment(FullscreenOut in [[stage_in]],
                                 constant PostUniforms &post [[buffer(0)]],
                                 constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                 texture2d<float> aoTex [[texture(0)]],
                                 depth2d<float> depthTex [[texture(1)]]) {
    float centerDepth = linearDepth(depthTex.sample(pointClamp, in.uv), frame.inverseProjection);
    float sum = 0.0f, weight = 0.0f;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            float2 uv = in.uv + float2(x, y) * post.texel.xy;
            float d = linearDepth(depthTex.sample(pointClamp, uv), frame.inverseProjection);
            float w = exp(-abs(d - centerDepth) / max(centerDepth * 0.05f, 1e-3f));
            sum += aoTex.sample(pointClamp, uv).r * w;
            weight += w;
        }
    }
    return float4(sum / max(weight, 1e-4f));
}

// MARK: - Temporal anti-aliasing and temporal upscaling

inline float3 rgbToYCoCg(float3 c) {
    return float3(0.25f * c.r + 0.5f * c.g + 0.25f * c.b, 0.5f * c.r - 0.5f * c.b, -0.25f * c.r + 0.5f * c.g - 0.25f * c.b);
}

inline float3 yCoCgToRgb(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

/// Karis weighting: compresses HDR so bright pixels do not dominate the filter.
inline float3 tonemapWeighted(float3 c) { return c / (1.0f + luminance(c)); }
inline float3 untonemapWeighted(float3 c) { return c / max(1.0f - luminance(c), 1e-4f); }

/// 5-tap Catmull–Rom history sample (Jimenez 2016, "Filmic SMAA").
inline float3 sampleCatmullRom(texture2d<float> tex, float2 uv, float2 size) {
    float2 pos = uv * size;
    float2 center = floor(pos - 0.5f) + 0.5f;
    float2 f = pos - center;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = -0.5f * f3 + f2 - 0.5f * f;
    float2 w1 = 1.5f * f3 - 2.5f * f2 + 1.0f;
    float2 w2 = -1.5f * f3 + 2.0f * f2 + 0.5f * f;
    float2 w3 = 0.5f * f3 - 0.5f * f2;
    float2 w12 = w1 + w2;
    float2 tc12 = (center + w2 / w12) / size;
    float2 tc0 = (center - 1.0f) / size;
    float2 tc3 = (center + 2.0f) / size;
    float3 c = tex.sample(linearClampS, float2(tc12.x, tc0.y)).rgb * (w12.x * w0.y)
             + tex.sample(linearClampS, float2(tc0.x, tc12.y)).rgb * (w0.x * w12.y)
             + tex.sample(linearClampS, tc12).rgb * (w12.x * w12.y)
             + tex.sample(linearClampS, float2(tc3.x, tc12.y)).rgb * (w3.x * w12.y)
             + tex.sample(linearClampS, float2(tc12.x, tc3.y)).rgb * (w12.x * w3.y);
    float norm = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(c / max(norm, 1e-4f), 0.0f);
}

/// TAA resolve. When the destination is larger than the source this acts as a temporal
/// upscaler: the jittered low-resolution samples are splatted with a Gaussian kernel
/// around each output pixel and accumulated into full-resolution history.
fragment float4 taaResolveFragment(FullscreenOut in [[stage_in]],
                                   constant PostUniforms &post [[buffer(0)]],
                                   constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                   texture2d<float> current [[texture(0)]],
                                   texture2d<float> history [[texture(1)]],
                                   texture2d<float> motionTex [[texture(2)]],
                                   depth2d<float> depthTex [[texture(3)]]) {
    float2 srcSize = post.sizes.xy;
    float2 dstSize = post.sizes.zw;
    float2 uv = in.uv;
    // Position of this output pixel in source pixels, compensating the current jitter
    // (jitter is in NDC, +y up; texture space is +y down).
    float2 jitterPx = frame.jitter.xy * float2(0.5f, -0.5f) * srcSize;
    float2 srcPos = uv * srcSize - 0.5f + jitterPx;
    float2 base = floor(srcPos);
    float upscale = max(dstSize.x / srcSize.x, 1.0f);

    float3 sum = float3(0.0f);
    float weightSum = 0.0f;
    float3 m1 = float3(0.0f), m2 = float3(0.0f);
    float closestDepth = 0.0f;
    float2 closestUV = uv;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            float2 texel = base + float2(x, y);
            float2 tuv = (texel + 0.5f) / srcSize;
            float3 c = tonemapWeighted(current.sample(pointClamp, tuv).rgb);
            float2 d = texel - srcPos;
            // Gaussian splat; widened slightly when upscaling to avoid holes.
            float sigma = 0.47f * upscale;
            float w = exp(-dot(d, d) / (2.0f * sigma * sigma));
            sum += c * w;
            weightSum += w;
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
                m1 += c;
                m2 += c * c;
                float dz = depthTex.sample(pointClamp, tuv);
                if (dz > closestDepth) { closestDepth = dz; closestUV = tuv; }  // reverse-Z: nearest = largest
            }
        }
    }
    float3 currentColor = sum / max(weightSum, 1e-4f);
    // Neighbourhood statistics from the 3×3 around the nearest source texel.
    m1 = float3(0.0f); m2 = float3(0.0f);
    float2 nearest = (floor(srcPos + 0.5f) + 0.5f) / srcSize;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float3 c = rgbToYCoCg(tonemapWeighted(current.sample(pointClamp, nearest + float2(x, y) / srcSize).rgb));
            m1 += c;
            m2 += c * c;
        }
    }
    float3 mean = m1 / 9.0f;
    float3 sigma = sqrt(max(m2 / 9.0f - mean * mean, 0.0f));
    float gammaClip = 1.0f;
    float3 boxMin = mean - gammaClip * sigma;
    float3 boxMax = mean + gammaClip * sigma;

    float2 motion = motionTex.sample(pointClamp, closestUV).xy;
    float2 historyUV = uv - motion;
    bool offscreen = any(historyUV < 0.0f) || any(historyUV > 1.0f);
    if (post.taa.w > 0.5f || offscreen) {
        return float4(untonemapWeighted(currentColor), 1.0f);
    }
    float3 hist = rgbToYCoCg(tonemapWeighted(sampleCatmullRom(history, historyUV, dstSize)));
    // Clip towards the mean (variance clipping, Salvi 2016) rather than clamping per channel.
    float3 center = (boxMin + boxMax) * 0.5f;
    float3 extents = max((boxMax - boxMin) * 0.5f, 1e-4f);
    float3 offset = hist - center;
    float3 ts = abs(offset / extents);
    float t = max(max(ts.x, ts.y), ts.z);
    if (t > 1.0f) { hist = center + offset / t; }
    float3 histRGB = yCoCgToRgb(hist);

    // Blend: more current weight under fast motion and when this output pixel received a
    // nearby sample this frame (upscaling confidence).
    float motionPx = length(motion * dstSize);
    float confidence = saturate(weightSum / 4.0f);
    float alpha = clamp(post.taa.x, 0.02f, 1.0f);
    alpha = mix(alpha, 1.0f, saturate(motionPx / 64.0f));
    alpha = clamp(alpha * mix(0.5f, 1.5f, confidence), 0.02f, 1.0f);
    float3 result = mix(histRGB, currentColor, alpha);
    return float4(untonemapWeighted(result), 1.0f);
}

// MARK: - Bloom (Jimenez 2014, "Next Generation Post Processing in Call of Duty")

inline float3 bloomThreshold(float3 c, float threshold, float knee) {
    float br = max(max(c.r, c.g), c.b);
    float rq = clamp(br - threshold + knee, 0.0f, 2.0f * knee);
    rq = rq * rq / max(4.0f * knee, 1e-4f);
    float w = max(rq, br - threshold) / max(br, 1e-4f);
    return c * w;
}

inline float karisWeight(float3 c) { return 1.0f / (1.0f + luminance(c)); }

/// 13-tap downsample. Pass index 0 (`misc.w`) also applies the threshold and Karis average
/// (suppresses fireflies).
fragment float4 bloomDownsampleFragment(FullscreenOut in [[stage_in]],
                                        constant PostUniforms &post [[buffer(0)]],
                                        texture2d<float> src [[texture(0)]]) {
    float2 t = post.texel.xy;
    float2 uv = in.uv;
    float3 a = src.sample(linearClampS, uv + t * float2(-2, -2)).rgb;
    float3 b = src.sample(linearClampS, uv + t * float2(0, -2)).rgb;
    float3 c = src.sample(linearClampS, uv + t * float2(2, -2)).rgb;
    float3 d = src.sample(linearClampS, uv + t * float2(-2, 0)).rgb;
    float3 e = src.sample(linearClampS, uv).rgb;
    float3 f = src.sample(linearClampS, uv + t * float2(2, 0)).rgb;
    float3 g = src.sample(linearClampS, uv + t * float2(-2, 2)).rgb;
    float3 h = src.sample(linearClampS, uv + t * float2(0, 2)).rgb;
    float3 i = src.sample(linearClampS, uv + t * float2(2, 2)).rgb;
    float3 j = src.sample(linearClampS, uv + t * float2(-1, -1)).rgb;
    float3 k = src.sample(linearClampS, uv + t * float2(1, -1)).rgb;
    float3 l = src.sample(linearClampS, uv + t * float2(-1, 1)).rgb;
    float3 m = src.sample(linearClampS, uv + t * float2(1, 1)).rgb;
    float3 result;
    if (post.misc.w < 0.5f) {
        float3 g0 = (a + b + d + e) * 0.25f, g1 = (b + c + e + f) * 0.25f;
        float3 g2 = (d + e + g + h) * 0.25f, g3 = (e + f + h + i) * 0.25f;
        float3 g4 = (j + k + l + m) * 0.25f;
        float w0 = karisWeight(g0) * 0.125f, w1 = karisWeight(g1) * 0.125f;
        float w2 = karisWeight(g2) * 0.125f, w3 = karisWeight(g3) * 0.125f;
        float w4 = karisWeight(g4) * 0.5f;
        result = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / max(w0 + w1 + w2 + w3 + w4, 1e-4f);
        result = bloomThreshold(result, post.bloom.x, post.bloom.y);
    } else {
        result = e * 0.125f + (a + c + g + i) * 0.03125f + (b + d + f + h) * 0.0625f + (j + k + l + m) * 0.125f;
    }
    return float4(max(result, 0.0f), 1.0f);
}

/// 3×3 tent upsample, additively blended (pipeline blend one/one) into the next larger mip.
fragment float4 bloomUpsampleFragment(FullscreenOut in [[stage_in]],
                                      constant PostUniforms &post [[buffer(0)]],
                                      texture2d<float> src [[texture(0)]]) {
    float2 t = post.texel.xy * post.bloom.w;
    float2 uv = in.uv;
    float3 c = src.sample(linearClampS, uv + float2(-t.x, -t.y)).rgb
             + src.sample(linearClampS, uv + float2(0.0f, -t.y)).rgb * 2.0f
             + src.sample(linearClampS, uv + float2(t.x, -t.y)).rgb
             + src.sample(linearClampS, uv + float2(-t.x, 0.0f)).rgb * 2.0f
             + src.sample(linearClampS, uv).rgb * 4.0f
             + src.sample(linearClampS, uv + float2(t.x, 0.0f)).rgb * 2.0f
             + src.sample(linearClampS, uv + float2(-t.x, t.y)).rgb
             + src.sample(linearClampS, uv + float2(0.0f, t.y)).rgb * 2.0f
             + src.sample(linearClampS, uv + float2(t.x, t.y)).rgb;
    return float4(c / 16.0f, 1.0f);
}

// MARK: - Depth of field (thin-lens circle of confusion, single-pass gather)

inline float circleOfConfusion(float viewDepth, constant PostUniforms &post, float viewportHeight) {
    float focus = max(post.dof.x, 0.01f);
    float f = max(post.dof.z, 0.001f);
    float aperture = f / max(post.dof.y, 0.1f);
    float z = max(viewDepth, 0.01f);
    float coc = aperture * f * (z - focus) / (z * max(focus - f, 1e-4f));  // metres on the sensor
    const float sensorHeight = 0.024f;  // full-frame 35 mm
    float px = coc / sensorHeight * viewportHeight;
    return clamp(px, -post.dof.w, post.dof.w);
}

fragment float4 dofFragment(FullscreenOut in [[stage_in]],
                            constant PostUniforms &post [[buffer(0)]],
                            constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                            texture2d<float> color [[texture(0)]],
                            depth2d<float> depthTex [[texture(1)]]) {
    float centerDepth = linearDepth(depthTex.sample(pointClamp, in.uv), frame.inverseProjection);
    float centerCoC = circleOfConfusion(centerDepth, post, post.sizes.y);
    float3 sharp = color.sample(pointClamp, in.uv).rgb;
    const int samples = 32;
    const float goldenAngle = 2.39996323f;
    float3 sum = sharp;
    float weight = 1.0f;
    float maxRadius = post.dof.w;
    for (int i = 1; i < samples; i++) {
        float r = sqrt(float(i) / float(samples)) * maxRadius;
        float theta = float(i) * goldenAngle;
        float2 offset = float2(cos(theta), sin(theta)) * r;
        float2 uv = in.uv + offset * post.texel.xy;
        float d = linearDepth(depthTex.sample(pointClamp, uv), frame.inverseProjection);
        float coc = circleOfConfusion(d, post, post.sizes.y);
        // A sample contributes if its own blur reaches this pixel. Background samples are
        // limited by the centre CoC so in-focus foreground does not bleed outwards.
        float reach = abs(coc);
        if (d > centerDepth) { reach = min(reach, abs(centerCoC) * 2.0f); }
        float w = saturate(reach - r + 1.0f);
        sum += color.sample(linearClampS, uv).rgb * w;
        weight += w;
    }
    float3 blurred = sum / weight;
    float blend = saturate(abs(centerCoC) / 2.0f);
    return float4(mix(sharp, blurred, blend), 1.0f);
}

// MARK: - Motion blur (per-pixel velocity, depth-aware)

fragment float4 motionBlurFragment(FullscreenOut in [[stage_in]],
                                   constant PostUniforms &post [[buffer(0)]],
                                   constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                   texture2d<float> color [[texture(0)]],
                                   texture2d<float> motionTex [[texture(1)]],
                                   depth2d<float> depthTex [[texture(2)]]) {
    float2 v = motionTex.sample(pointClamp, in.uv).xy * post.motionBlur.x;
    float2 vPx = v * post.sizes.xy;
    float len = length(vPx);
    float3 c = color.sample(pointClamp, in.uv).rgb;
    if (len < 0.5f) { return float4(c, 1.0f); }
    if (len > post.motionBlur.z) { v *= post.motionBlur.z / len; }
    int n = clamp(int(post.motionBlur.y), 2, 32);
    float centerDepth = depthTex.sample(pointClamp, in.uv);
    float noise = interleavedGradientNoise(in.position.xy, post.misc.x) - 0.5f;
    float3 sum = c;
    float weight = 1.0f;
    for (int i = 0; i < n; i++) {
        float t = (float(i) + 0.5f + noise) / float(n) - 0.5f;
        float2 uv = in.uv + v * t;
        float sd = depthTex.sample(pointClamp, uv);
        float2 sv = motionTex.sample(pointClamp, uv).xy * post.motionBlur.x;
        // Foreground samples always blur; background samples only if they move as well.
        float w = sd >= centerDepth ? 1.0f : saturate(length(sv * post.sizes.xy) / max(len, 1e-3f));
        sum += color.sample(linearClampS, uv).rgb * w;
        weight += w;
    }
    return float4(sum / weight, 1.0f);
}

// MARK: - Auto exposure (log-luminance histogram)

#define HISTOGRAM_BINS 128u
#define HISTOGRAM_MIN_EV (-10.0f)
#define HISTOGRAM_MAX_EV (20.0f)

kernel void luminanceHistogram(texture2d<float> hdr [[texture(0)]],
                               device atomic_uint *histogram [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]],
                               uint lid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint local[HISTOGRAM_BINS];
    if (lid < HISTOGRAM_BINS) { atomic_store_explicit(&local[lid], 0u, memory_order_relaxed); }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (gid.x < hdr.get_width() && gid.y < hdr.get_height()) {
        float3 c = hdr.read(gid).rgb;
        float lum = luminance(c);
        if (lum > 1e-5f) {
            float ev = log2(lum);
            float t = saturate((ev - HISTOGRAM_MIN_EV) / (HISTOGRAM_MAX_EV - HISTOGRAM_MIN_EV));
            uint bin = min(uint(t * float(HISTOGRAM_BINS - 1u)) + 1u, HISTOGRAM_BINS - 1u);
            atomic_fetch_add_explicit(&local[bin], 1u, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&local[0], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid < HISTOGRAM_BINS) {
        uint v = atomic_load_explicit(&local[lid], memory_order_relaxed);
        if (v > 0u) { atomic_fetch_add_explicit(&histogram[lid], v, memory_order_relaxed); }
    }
}

/// Single-threadgroup reduction: averages the histogram (ignoring the darkest and brightest
/// tails) and adapts the exposure stored in `exposure[0]` exponentially over time.
kernel void adaptExposure(constant PostUniforms &post [[buffer(0)]],
                          device atomic_uint *histogram [[buffer(1)]],
                          device float *exposure [[buffer(2)]],
                          uint lid [[thread_index_in_threadgroup]]) {
    threadgroup float weighted[HISTOGRAM_BINS];
    threadgroup uint counts[HISTOGRAM_BINS];
    uint c = atomic_load_explicit(&histogram[lid], memory_order_relaxed);
    counts[lid] = c;
    weighted[lid] = lid == 0u ? 0.0f : float(c) * float(lid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid == 0u) {
        uint total = 0u;
        for (uint i = 1u; i < HISTOGRAM_BINS; i++) { total += counts[i]; }
        // Discard the darkest 50 % and brightest 2 % (common photographic metering).
        float lowCut = float(total) * 0.5f, highCut = float(total) * 0.98f;
        float acc = 0.0f, sum = 0.0f, n = 0.0f;
        for (uint i = 1u; i < HISTOGRAM_BINS; i++) {
            float cnt = float(counts[i]);
            float lo = max(lowCut - acc, 0.0f);
            float hi = max(acc + cnt - highCut, 0.0f);
            float use = max(cnt - lo - hi, 0.0f);
            sum += use * float(i);
            n += use;
            acc += cnt;
        }
        float bin = n > 0.0f ? sum / n : float(HISTOGRAM_BINS) * 0.5f;
        float ev = HISTOGRAM_MIN_EV + (bin - 1.0f) / float(HISTOGRAM_BINS - 1u) * (HISTOGRAM_MAX_EV - HISTOGRAM_MIN_EV);
        float avgLum = exp2(ev);
        float target = 0.18f / max(avgLum, 1e-4f);
        float current = exposure[0];
        float speed = max(post.misc.z, 0.01f);
        float k = 1.0f - exp(-post.misc.y * speed);
        exposure[0] = current <= 0.0f ? target : mix(current, target, k);
    }
    threadgroup_barrier(mem_flags::mem_device);
    atomic_store_explicit(&histogram[lid], 0u, memory_order_relaxed);
}

// MARK: - Tone mapping and grading

inline float3 tonemapReinhard(float3 c) {
    float l = luminance(c);
    const float white = 4.0f;
    float ln = l * (1.0f + l / (white * white)) / (1.0f + l);
    return c * (ln / max(l, 1e-5f));
}

/// ACES filmic fit (Stephen Hill), applied in ACES AP1-ish space via the RRT/ODT fit.
inline float3 tonemapACES(float3 c) {
    float3 v = float3(dot(float3(0.59719f, 0.35458f, 0.04823f), c),
                      dot(float3(0.07600f, 0.90834f, 0.01566f), c),
                      dot(float3(0.02840f, 0.13383f, 0.83777f), c));
    float3 a = v * (v + 0.0245786f) - 0.000090537f;
    float3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
    v = a / b;
    float3 o = float3(dot(float3(1.60475f, -0.53108f, -0.07367f), v),
                      dot(float3(-0.10208f, 1.10813f, -0.00605f), v),
                      dot(float3(-0.00327f, -0.07276f, 1.07602f), v));
    return saturate(o);
}

/// AgX base look (Sobotka), polynomial contrast fit; returns linear display values.
inline float3 tonemapAgX(float3 c) {
    const float3x3 inset = float3x3(float3(0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f),
                                    float3(0.0784335999999992f, 0.878468636469772f, 0.0784336f),
                                    float3(0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f));
    const float3x3 outset = float3x3(float3(1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f),
                                     float3(-0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f),
                                     float3(-0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f));
    const float minEV = -12.47393f, maxEV = 4.026069f;
    float3 x = inset * max(c, 1e-10f);
    x = clamp(log2(x), minEV, maxEV);
    x = (x - minEV) / (maxEV - minEV);
    float3 x2 = x * x, x4 = x2 * x2;
    x = 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
    x = outset * x;
    return pow(saturate(x), 2.2f);
}

inline float3 applyWhiteBalance(float3 c, float3 lmsScale) {
    const float3x3 toLMS = float3x3(float3(3.90405e-1f, 7.08416e-2f, 2.31082e-2f),
                                    float3(5.49941e-1f, 9.63172e-1f, 1.28021e-1f),
                                    float3(8.92632e-3f, 1.35775e-3f, 9.36245e-1f));
    const float3x3 fromLMS = float3x3(float3(2.85847f, -2.10182e-1f, -4.18120e-2f),
                                      float3(-1.62879f, 1.15820f, -1.18169e-1f),
                                      float3(-2.48910e-2f, 3.24281e-4f, 1.06867f));
    return fromLMS * ((toLMS * c) * lmsScale);
}

fragment float4 tonemapFragment(FullscreenOut in [[stage_in]],
                                constant PostUniforms &post [[buffer(0)]],
                                texture2d<float> hdr [[texture(0)]],
                                texture2d<float> bloomTex [[texture(1)]],
                                const device float *autoExposure [[buffer(2)]]) {
    float3 c = hdr.sample(linearClampS, in.uv).rgb;
    if (post.bloom.z > 0.0f) { c += bloomTex.sample(linearClampS, in.uv).rgb * post.bloom.z; }
    float exposure = post.tonemap.y;
    if (post.lift.a > 0.5f) { exposure *= max(autoExposure[0], 1e-4f); }
    c *= exposure;
    c = applyWhiteBalance(c, post.whiteBalance.xyz);
    // Contrast in log space around middle grey.
    const float midGrey = 0.18f;
    c = max(c, 0.0f);
    c = exp2((log2(c + 1e-6f) - log2(midGrey)) * post.tonemap.z + log2(midGrey));
    float l = luminance(c);
    c = max(mix(float3(l), c, post.tonemap.w), 0.0f);

    uint op = uint(post.tonemap.x);
    if (op == 1u) { c = tonemapReinhard(c); }
    else if (op == 2u) { c = tonemapACES(c); }
    else if (op == 3u) { c = tonemapAgX(c); }
    else { c = saturate(c); }

    // Lift / gamma / gain on display-referred values.
    c = saturate(post.gain.rgb * (c + post.lift.rgb * (1.0f - c)));
    c = pow(c, 1.0f / max(post.gamma.rgb, float3(0.01f)));

    // Vignette.
    float2 d = (in.uv - 0.5f) * float2(post.sizes.z / max(post.sizes.w, 1.0f), 1.0f);
    float vig = 1.0f - post.whiteBalance.w * smoothstep(0.3f, 1.0f, length(d) * 1.4f);
    c *= vig;

    // Encode to sRGB (the LDR targets are unorm, not *_srgb) and dither to hide banding.
    float3 encoded = linearToSRGB(saturate(c));
    float dither = (interleavedGradientNoise(in.position.xy, post.misc.x) - 0.5f) / 255.0f * post.gamma.a;
    return float4(saturate(encoded + dither), 1.0f);
}

// MARK: - FXAA (Lottes, quality variant with 8-step edge search)

inline float lumaOf(float3 c) { return dot(c, float3(0.299f, 0.587f, 0.114f)); }

fragment float4 fxaaFragment(FullscreenOut in [[stage_in]],
                             constant PostUniforms &post [[buffer(0)]],
                             texture2d<float> src [[texture(0)]]) {
    float2 t = post.texel.xy;
    float2 uv = in.uv;
    float3 cM = src.sample(pointClamp, uv).rgb;
    float lM = lumaOf(cM);
    float lN = lumaOf(src.sample(pointClamp, uv + float2(0, -t.y)).rgb);
    float lS = lumaOf(src.sample(pointClamp, uv + float2(0, t.y)).rgb);
    float lE = lumaOf(src.sample(pointClamp, uv + float2(t.x, 0)).rgb);
    float lW = lumaOf(src.sample(pointClamp, uv + float2(-t.x, 0)).rgb);
    float lMax = max(max(max(lN, lS), max(lE, lW)), lM);
    float lMin = min(min(min(lN, lS), min(lE, lW)), lM);
    float range = lMax - lMin;
    if (range < max(0.0312f, lMax * 0.125f)) { return float4(cM, 1.0f); }

    float lNW = lumaOf(src.sample(pointClamp, uv + float2(-t.x, -t.y)).rgb);
    float lNE = lumaOf(src.sample(pointClamp, uv + float2(t.x, -t.y)).rgb);
    float lSW = lumaOf(src.sample(pointClamp, uv + float2(-t.x, t.y)).rgb);
    float lSE = lumaOf(src.sample(pointClamp, uv + float2(t.x, t.y)).rgb);

    float edgeH = abs(lNW + lNE - 2.0f * lN) + 2.0f * abs(lW + lE - 2.0f * lM) + abs(lSW + lSE - 2.0f * lS);
    float edgeV = abs(lNW + lSW - 2.0f * lW) + 2.0f * abs(lN + lS - 2.0f * lM) + abs(lNE + lSE - 2.0f * lE);
    bool horizontal = edgeH >= edgeV;

    float l1 = horizontal ? lN : lW;
    float l2 = horizontal ? lS : lE;
    float g1 = abs(l1 - lM), g2 = abs(l2 - lM);
    bool steepest1 = g1 >= g2;
    float gScaled = 0.25f * max(g1, g2);
    float stepLen = horizontal ? t.y : t.x;
    float lLocal = steepest1 ? (l1 + lM) * 0.5f : (l2 + lM) * 0.5f;
    if (steepest1) { stepLen = -stepLen; }

    float2 cur = uv;
    if (horizontal) { cur.y += stepLen * 0.5f; } else { cur.x += stepLen * 0.5f; }
    float2 off = horizontal ? float2(t.x, 0) : float2(0, t.y);
    float2 uv1 = cur - off, uv2 = cur + off;
    float e1 = lumaOf(src.sample(linearClampS, uv1).rgb) - lLocal;
    float e2 = lumaOf(src.sample(linearClampS, uv2).rgb) - lLocal;
    bool r1 = abs(e1) >= gScaled, r2 = abs(e2) >= gScaled;
    const float steps[8] = { 1.0f, 1.0f, 1.5f, 2.0f, 2.0f, 2.0f, 4.0f, 8.0f };
    for (int i = 0; i < 8 && !(r1 && r2); i++) {
        if (!r1) { uv1 -= off * steps[i]; e1 = lumaOf(src.sample(linearClampS, uv1).rgb) - lLocal; r1 = abs(e1) >= gScaled; }
        if (!r2) { uv2 += off * steps[i]; e2 = lumaOf(src.sample(linearClampS, uv2).rgb) - lLocal; r2 = abs(e2) >= gScaled; }
    }
    float d1 = horizontal ? uv.x - uv1.x : uv.y - uv1.y;
    float d2 = horizontal ? uv2.x - uv.x : uv2.y - uv.y;
    bool closer1 = d1 < d2;
    float dMin = min(d1, d2);
    float edgeLen = d1 + d2;
    float pixelOffset = -dMin / max(edgeLen, 1e-6f) + 0.5f;
    bool lMSmaller = lM < lLocal;
    bool correct = ((closer1 ? e1 : e2) < 0.0f) != lMSmaller;
    float finalOffset = correct ? pixelOffset : 0.0f;

    // Sub-pixel aliasing removal.
    float lAvg = (2.0f * (lN + lS + lE + lW) + lNW + lNE + lSW + lSE) / 12.0f;
    float sub = saturate(abs(lAvg - lM) / range);
    sub = smoothstep(0.0f, 1.0f, sub);
    float subOffset = sub * sub * 0.75f;
    finalOffset = max(finalOffset, subOffset);

    float2 finalUV = uv;
    if (horizontal) { finalUV.y += finalOffset * stepLen; } else { finalUV.x += finalOffset * stepLen; }
    return float4(src.sample(linearClampS, finalUV).rgb, 1.0f);
}

// MARK: - SMAA-style morphological AA
//
// A three-pass morphological filter following the structure of SMAA 1x (edge detection,
// blending weights, neighbourhood blending). Instead of SMAA's precomputed area and search
// textures, the blending weights are computed analytically from edge lengths (MLAA-style
// linear area estimate). Quality sits between FXAA and full SMAA; see Docs/09.

fragment float4 smaaEdgeFragment(FullscreenOut in [[stage_in]],
                                 constant PostUniforms &post [[buffer(0)]],
                                 texture2d<float> src [[texture(0)]]) {
    float2 t = post.texel.xy;
    float l = lumaOf(src.sample(pointClamp, in.uv).rgb);
    float lLeft = lumaOf(src.sample(pointClamp, in.uv + float2(-t.x, 0)).rgb);
    float lTop = lumaOf(src.sample(pointClamp, in.uv + float2(0, -t.y)).rgb);
    float lRight = lumaOf(src.sample(pointClamp, in.uv + float2(t.x, 0)).rgb);
    float lBottom = lumaOf(src.sample(pointClamp, in.uv + float2(0, t.y)).rgb);
    float lLeft2 = lumaOf(src.sample(pointClamp, in.uv + float2(-2.0f * t.x, 0)).rgb);
    float lTop2 = lumaOf(src.sample(pointClamp, in.uv + float2(0, -2.0f * t.y)).rgb);
    const float threshold = 0.1f;
    float2 delta = abs(l - float2(lLeft, lTop));
    float2 edges = step(threshold, delta);
    if (edges.x + edges.y == 0.0f) { return float4(0.0f); }
    // Local contrast adaptation: suppress edges much weaker than their neighbours.
    float2 deltaMax = max(abs(float2(lRight, lBottom) - l), abs(float2(lLeft2, lTop2) - float2(lLeft, lTop)));
    float finalMax = max(max(deltaMax.x, deltaMax.y), max(delta.x, delta.y));
    edges *= step(finalMax, 2.0f * delta);
    return float4(edges, 0.0f, 0.0f);
}

/// Searches along an edge for its end (up to 16 pixels).
inline float searchEdge(texture2d<float> edges, float2 uv, float2 dir, float2 t, int component) {
    float dist = 0.0f;
    for (int i = 1; i <= 16; i++) {
        float4 e = edges.sample(pointClamp, uv + dir * t * float(i));
        if (e[component] < 0.5f) { break; }
        dist = float(i);
    }
    return dist;
}

fragment float4 smaaWeightsFragment(FullscreenOut in [[stage_in]],
                                    constant PostUniforms &post [[buffer(0)]],
                                    texture2d<float> edges [[texture(0)]]) {
    float2 t = post.texel.xy;
    float4 e = edges.sample(pointClamp, in.uv);
    float4 weights = float4(0.0f);
    if (e.y > 0.5f) {
        // Edge on top: horizontal line. Measure its extent left and right.
        float left = searchEdge(edges, in.uv, float2(-1, 0), t, 1);
        float right = searchEdge(edges, in.uv, float2(1, 0), t, 1);
        float len = left + right + 1.0f;
        // Linear area under the reconstructed edge at this pixel (MLAA estimate).
        float pos = (left + 0.5f) / len;
        float area = 0.5f * (1.0f - abs(pos * 2.0f - 1.0f)) * saturate(len / 4.0f);
        weights.x = area;      // blend with top neighbour
        weights.y = area;      // and mirrored for the pixel above (applied in blending pass)
    }
    if (e.x > 0.5f) {
        float up = searchEdge(edges, in.uv, float2(0, -1), t, 0);
        float down = searchEdge(edges, in.uv, float2(0, 1), t, 0);
        float len = up + down + 1.0f;
        float pos = (up + 0.5f) / len;
        float area = 0.5f * (1.0f - abs(pos * 2.0f - 1.0f)) * saturate(len / 4.0f);
        weights.z = area;
        weights.w = area;
    }
    return weights;
}

fragment float4 smaaBlendFragment(FullscreenOut in [[stage_in]],
                                  constant PostUniforms &post [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> weights [[texture(1)]]) {
    float2 t = post.texel.xy;
    float4 w = weights.sample(pointClamp, in.uv);
    // Weights stored on the neighbour below / right refer to this pixel's bottom/right edge.
    float wBottom = weights.sample(pointClamp, in.uv + float2(0, t.y)).y;
    float wRight = weights.sample(pointClamp, in.uv + float2(t.x, 0)).w;
    float wTop = w.x, wLeft = w.z;
    float total = wTop + wBottom + wLeft + wRight;
    float3 c = src.sample(pointClamp, in.uv).rgb;
    if (total < 1e-4f) { return float4(c, 1.0f); }
    float3 blended = c * (1.0f - min(total, 1.0f))
                   + src.sample(pointClamp, in.uv + float2(0, -t.y)).rgb * wTop
                   + src.sample(pointClamp, in.uv + float2(0, t.y)).rgb * wBottom
                   + src.sample(pointClamp, in.uv + float2(-t.x, 0)).rgb * wLeft
                   + src.sample(pointClamp, in.uv + float2(t.x, 0)).rgb * wRight;
    float norm = (1.0f - min(total, 1.0f)) + total;
    return float4(blended / norm, 1.0f);
}

// MARK: - Contrast-adaptive sharpening (after the idea of AMD FidelityFX CAS)

fragment float4 sharpenFragment(FullscreenOut in [[stage_in]],
                                constant PostUniforms &post [[buffer(0)]],
                                texture2d<float> src [[texture(0)]]) {
    float2 t = post.texel.xy;
    float3 b = src.sample(pointClamp, in.uv + float2(0, -t.y)).rgb;
    float3 d = src.sample(pointClamp, in.uv + float2(-t.x, 0)).rgb;
    float3 e = src.sample(pointClamp, in.uv).rgb;
    float3 f = src.sample(pointClamp, in.uv + float2(t.x, 0)).rgb;
    float3 h = src.sample(pointClamp, in.uv + float2(0, t.y)).rgb;
    float3 mn = min(min(min(b, d), min(f, h)), e);
    float3 mx = max(max(max(b, d), max(f, h)), e);
    // Amount of sharpening scales with how much headroom the local range leaves.
    float3 amp = saturate(min(mn, 1.0f - mx) / max(mx, 1e-4f));
    amp = sqrt(amp);
    float peak = -1.0f / mix(8.0f, 5.0f, saturate(post.sharpen.x));
    float3 w = amp * peak;
    float3 result = (b * w + d * w + f * w + h * w + e) / (1.0f + 4.0f * w);
    return float4(saturate(result), 1.0f);
}

// MARK: - Ferox spatial upscaler (edge-adaptive Lanczos-2 with ringing clamp)

inline float lanczos2(float x) {
    x = abs(x);
    if (x < 1e-5f) { return 1.0f; }
    if (x >= 2.0f) { return 0.0f; }
    float px = FEROX_PI * x;
    return 2.0f * sin(px) * sin(px * 0.5f) / (px * px);
}

fragment float4 spatialUpscaleFragment(FullscreenOut in [[stage_in]],
                                       constant PostUniforms &post [[buffer(0)]],
                                       texture2d<float> src [[texture(0)]]) {
    float2 srcSize = post.sizes.xy;
    float2 pos = in.uv * srcSize - 0.5f;
    float2 base = floor(pos);
    float2 f = pos - base;
    // Edge direction from the local luma gradient; the kernel is stretched along the edge.
    float2 tc = (base + 0.5f) / srcSize;
    float2 t = post.texel.xy;
    float gx = lumaOf(src.sample(pointClamp, tc + float2(t.x, 0)).rgb) - lumaOf(src.sample(pointClamp, tc - float2(t.x, 0)).rgb);
    float gy = lumaOf(src.sample(pointClamp, tc + float2(0, t.y)).rgb) - lumaOf(src.sample(pointClamp, tc - float2(0, t.y)).rgb);
    float2 grad = float2(gx, gy);
    float gl = length(grad);
    float2 edgeDir = gl > 1e-3f ? float2(-grad.y, grad.x) / gl : float2(1.0f, 0.0f);
    float anisotropy = saturate(gl * 4.0f);

    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    float3 mn = float3(1e9f), mx = float3(-1e9f);
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            float2 o = float2(x, y) - f;
            // Rotate into edge space: compress across the edge, stretch along it.
            float along = dot(o, edgeDir);
            float across = dot(o, float2(-edgeDir.y, edgeDir.x));
            float2 s = float2(along / (1.0f + anisotropy), across * (1.0f + anisotropy * 0.5f));
            float w = lanczos2(length(s));
            float3 c = src.sample(pointClamp, (base + float2(x, y) + 0.5f) / srcSize).rgb;
            sum += c * w;
            wsum += w;
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) { mn = min(mn, c); mx = max(mx, c); }
        }
    }
    float3 c = sum / max(wsum, 1e-4f);
    // Clamp to the nearest 2×2 range to remove Lanczos ringing.
    return float4(clamp(c, mn, mx), 1.0f);
}

// MARK: - Utility

/// Plain copy with bilinear filtering (also used to present into the drawable).
fragment float4 blitFragment(FullscreenOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.sample(linearClampS, in.uv);
}

/// Visualises a debug channel: misc.w selects 0 colour, 1 depth, 2 normals, 3 motion, 4 AO.
fragment float4 debugViewFragment(FullscreenOut in [[stage_in]],
                                  constant PostUniforms &post [[buffer(0)]],
                                  constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                  texture2d<float> src [[texture(0)]],
                                  depth2d<float> depthTex [[texture(1)]]) {
    uint mode = uint(post.misc.w);
    if (mode == 1u) {
        float d = linearDepth(depthTex.sample(pointClamp, in.uv), frame.inverseProjection);
        float v = saturate(log2(max(d, 0.01f)) / 10.0f);
        return float4(float3(v), 1.0f);
    }
    float4 c = src.sample(pointClamp, in.uv);
    if (mode == 3u) { return float4(abs(c.xy) * 20.0f, 0.0f, 1.0f); }
    if (mode == 4u) { return float4(c.rrr, 1.0f); }
    return float4(c.rgb, 1.0f);
}
