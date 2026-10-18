// Ferox — debug line rendering (physics shapes, bounds, gizmos).

struct LineVertex {
    float4 position;  // world space, w = 1
    float4 color;     // premultiplied
};

struct DebugUniforms {
    float4x4 viewProjection;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut debugLineVertex(const device LineVertex *vertices [[buffer(0)]],
                               constant DebugUniforms &u [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    LineOut o;
    o.position = u.viewProjection * float4(vertices[vid].position.xyz, 1.0f);
    o.color = vertices[vid].color;
    return o;
}

fragment float4 debugLineFragment(LineOut in [[stage_in]]) { return in.color; }
