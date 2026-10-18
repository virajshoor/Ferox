// Ferox — 2D sprites, shapes, tilemaps, 2D lights and masks.
//
// Everything 2D is batched on the CPU into `SpriteVertex` triangles (shapes and tilemaps
// are tessellated there too), so one pipeline per blend mode covers the whole 2D layer.
// Colours are premultiplied linear.

struct SpriteVertex {
    float2 position;
    float2 uv;
    float4 color;
    float2 extra;  // x receives lighting, y layer depth
};

struct Sprite2DUniforms {
    float4x4 viewProjection;
    float4 ambient;  // rgb ambient light for lit sprites, a unused
    uint4 counts;    // x light count, y flags (bit 0: normal map bound)
    float4 params;   // x pixel snap (0/1), yz render-target size in pixels, w mask alpha cut-off
};

struct Light2D {
    float4 positionRadius;  // xy world position, z height above the sprite plane, w radius
    float4 color;           // rgb colour × intensity, a falloff exponent
    float4 params;          // x inner radius fraction, y spot cos (≤ -1 = point light), zw spot direction
};

#define SPRITE_FLAG_NORMAL_MAP 1u

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 world;
    float lit;
};

vertex SpriteOut spriteVertex(const device SpriteVertex *vertices [[buffer(0)]],
                              constant Sprite2DUniforms &u [[buffer(1)]],
                              uint vid [[vertex_id]]) {
    SpriteVertex v = vertices[vid];
    SpriteOut o;
    float4 clip = u.viewProjection * float4(v.position, 0.0f, 1.0f);
    if (u.params.x > 0.5f) {
        // Snap to the pixel grid of the render target (pixel-perfect mode).
        float2 half_ = u.params.yz * 0.5f;
        float2 ndc = clip.xy / clip.w;
        ndc = (floor(ndc * half_ + 0.5f)) / half_;
        clip.xy = ndc * clip.w;
    }
    o.position = clip;
    o.uv = v.uv;
    o.color = v.color;
    o.world = v.position;
    o.lit = v.extra.x;
    return o;
}

inline float3 accumulate2DLights(float2 world, float3 normal, constant Sprite2DUniforms &u,
                                 const device Light2D *lights) {
    float3 sum = u.ambient.rgb;
    uint count = min(u.counts.x, 64u);
    for (uint i = 0; i < count; i++) {
        Light2D l = lights[i];
        float2 d = l.positionRadius.xy - world;
        float dist = length(d);
        float radius = max(l.positionRadius.w, 1e-4f);
        if (dist >= radius) { continue; }
        float t = saturate((dist / radius - l.params.x) / max(1.0f - l.params.x, 1e-4f));
        float atten = pow(1.0f - t, max(l.color.a, 0.01f));
        if (l.params.y > -1.0f) {
            float2 dir = normalize(l.params.zw);
            float c = dot(-d / max(dist, 1e-4f), dir);
            atten *= smoothstep(l.params.y, mix(l.params.y, 1.0f, 0.25f), c);
        }
        float3 L = normalize(float3(d, l.positionRadius.z));
        sum += l.color.rgb * atten * saturate(dot(normal, L));
    }
    return sum;
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]],
                               constant Sprite2DUniforms &u [[buffer(1)]],
                               const device Light2D *lights [[buffer(2)]],
                               texture2d<float> tex [[texture(0)]],
                               texture2d<float> normalMap [[texture(1)]],
                               sampler s [[sampler(0)]]) {
    float4 c = tex.sample(s, in.uv) * in.color;
    if (in.lit > 0.5f) {
        float3 n = float3(0.0f, 0.0f, 1.0f);
        if ((u.counts.y & SPRITE_FLAG_NORMAL_MAP) != 0u) {
            n = normalize(normalMap.sample(s, in.uv).xyz * 2.0f - 1.0f);
        }
        c.rgb *= accumulate2DLights(in.world, n, u, lights);
    }
    return c;
}

/// Writes the stencil mask; colour writes are disabled on this pipeline.
fragment float4 spriteMaskFragment(SpriteOut in [[stage_in]],
                                   constant Sprite2DUniforms &u [[buffer(1)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
    float a = tex.sample(s, in.uv).a * in.color.a;
    if (a < u.params.w) { discard_fragment(); }
    return float4(0.0f);
}
