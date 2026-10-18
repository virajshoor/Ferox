// Ferox — GPU particles.
//
// The CPU writes newly spawned particles into a ring buffer (`spawnParticles` copies them
// into dead slots); `simulateParticles` integrates every live particle; the billboard
// vertex shader expands each particle into a camera-facing quad (6 vertices).
// A particle with age >= life is dead and collapses to a degenerate quad.

struct GPUParticle {
    float4 posLife;   // xyz position, w lifetime (s)
    float4 velAge;    // xyz velocity, w age (s)
    float4 color;     // premultiplied, linear
    float4 sizeRot;   // x start size, y end size, z rotation (rad), w angular velocity
};

struct ParticleSimUniforms {
    float4 gravityDrag;  // xyz gravity, w linear drag
    float4 params;       // x dt, y fade-out fraction, zw unused
    uint4 counts;        // x capacity, y spawn count, z spawn ring offset, w unused
};

kernel void spawnParticles(constant ParticleSimUniforms &u [[buffer(0)]],
                           const device GPUParticle *spawned [[buffer(1)]],
                           device GPUParticle *particles [[buffer(3)]],
                           uint gid [[thread_position_in_grid]]) {
    if (gid >= u.counts.y || u.counts.x == 0u) { return; }
    particles[(u.counts.z + gid) % u.counts.x] = spawned[gid];
}

kernel void simulateParticles(constant ParticleSimUniforms &u [[buffer(0)]],
                              device GPUParticle *particles [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
    if (gid >= u.counts.x) { return; }
    GPUParticle p = particles[gid];
    if (p.velAge.w >= p.posLife.w) { return; }
    float dt = u.params.x;
    float3 v = p.velAge.xyz + u.gravityDrag.xyz * dt;
    v *= 1.0f / (1.0f + u.gravityDrag.w * dt);
    p.posLife.xyz += v * dt;
    p.velAge.xyz = v;
    p.velAge.w += dt;
    p.sizeRot.z += p.sizeRot.w * dt;
    particles[gid] = p;
}

struct ParticleOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex ParticleOut particleVertex(const device GPUParticle *particles [[buffer(3)]],
                                  constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                  constant ParticleSimUniforms &u [[buffer(0)]],
                                  uint vid [[vertex_id]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1),
                                float2(-1, -1), float2(1, 1), float2(-1, 1) };
    GPUParticle p = particles[vid / 6u];
    float2 c = corners[vid % 6u];
    ParticleOut o;
    float life = max(p.posLife.w, 1e-4f);
    float t = saturate(p.velAge.w / life);
    if (p.velAge.w >= p.posLife.w) {
        o.position = float4(0.0f, 0.0f, -2.0f, 1.0f);  // outside the clip volume
        o.uv = float2(0.0f);
        o.color = float4(0.0f);
        return o;
    }
    float size = mix(p.sizeRot.x, p.sizeRot.y, t) * 0.5f;
    float s = sin(p.sizeRot.z), co = cos(p.sizeRot.z);
    float2 r = float2(c.x * co - c.y * s, c.x * s + c.y * co) * size;
    float3 right = float3(frame.view[0][0], frame.view[1][0], frame.view[2][0]);
    float3 up = float3(frame.view[0][1], frame.view[1][1], frame.view[2][1]);
    float3 world = p.posLife.xyz + right * r.x + up * r.y;
    o.position = frame.viewProjection * float4(world, 1.0f);
    o.uv = c * 0.5f + 0.5f;
    // params.y = 0 disables the fade (CPU particles bake colour over lifetime).
    float fadeFraction = saturate(u.params.y);
    float fade = fadeFraction > 0.0f ? 1.0f - smoothstep(1.0f - fadeFraction, 1.0f, t) : 1.0f;
    o.color = p.color * fade;
    return o;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]],
                                 constant FrameUniforms &frame [[buffer(BUF_FRAME)]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv) * in.color * frame.exposure.x;
}
