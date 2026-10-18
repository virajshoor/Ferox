// Ferox — immediate-mode UI rendering.
//
// One pipeline draws every UI primitive. `params.z` selects the mode:
//   0 — solid rounded rectangle with optional border (signed-distance field),
//   1 — premultiplied texture (images, render targets) clipped by the rounded rect,
//   2 — R8 glyph coverage from the font atlas, tinted by the vertex colour.
// Clipping uses the render encoder's scissor rectangle.

struct UIVertex {
    float2 position;  // pixels, origin top-left
    float2 uv;
    float4 color;     // premultiplied
    float4 rect;      // xy centre, zw half size (pixels)
    float4 params;    // x corner radius, y border width, z mode, w unused
    float4 borderColor;
};

struct UIUniforms {
    float4 viewport;  // xy size in points, zw content scale
};

struct UIOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 local;  // position relative to rect centre (points)
    float4 rect;
    float4 params;
    float4 borderColor;
};

vertex UIOut uiVertex(const device UIVertex *vertices [[buffer(0)]],
                      constant UIUniforms &u [[buffer(1)]],
                      uint vid [[vertex_id]]) {
    UIVertex v = vertices[vid];
    UIOut o;
    float2 ndc = v.position / max(u.viewport.xy, float2(1.0f)) * 2.0f - 1.0f;
    o.position = float4(ndc.x, -ndc.y, 0.0f, 1.0f);
    o.uv = v.uv;
    o.color = v.color;
    o.local = v.position - v.rect.xy;
    o.rect = v.rect;
    o.params = v.params;
    o.borderColor = v.borderColor;
    return o;
}

inline float roundedRectSDF(float2 p, float2 halfSize, float radius) {
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

fragment float4 uiFragment(UIOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           sampler s [[sampler(0)]]) {
    uint mode = uint(in.params.z + 0.5f);
    if (mode == 2u) {
        float coverage = tex.sample(s, in.uv).r;
        return in.color * coverage;
    }
    float d = roundedRectSDF(in.local, in.rect.zw, in.params.x);
    float aa = max(fwidth(d), 1e-4f);
    float shape = 1.0f - smoothstep(-aa * 0.5f, aa * 0.5f, d);
    float4 fill = mode == 1u ? tex.sample(s, in.uv) * in.color : in.color;
    float border = in.params.y;
    if (border > 0.0f) {
        float inner = 1.0f - smoothstep(-aa * 0.5f, aa * 0.5f, d + border);
        fill = mix(in.borderColor, fill, inner);
    }
    return fill * shape;
}
