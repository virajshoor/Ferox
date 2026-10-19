// Encodes one indirect render command per opaque batch after GPU culling.
// Instance count is the value the cull kernels wrote at draw-args word 1.
// The CPU still knows how many batches exist; it does not know how many survived.
// A reset command is a no-op, so a batch with a zero count draws nothing.

struct ICBContainer {
    command_buffer commandBuffer [[id(0)]];
};

struct GPUDraw {
    render_pipeline_state pipeline [[id(0)]];
    device void *vertices [[id(1)]];
    device void *indexBuffer [[id(2)]];
    device void *skin [[id(3)]];
};

kernel void encodeCulledDraws(
    uint gid [[thread_position_in_grid]],
    device ICBContainer *icbContainer [[buffer(0)]],
    const device GPUDraw *draws [[buffer(1)]],
    const device uint *drawArgs [[buffer(2)]],
    const device void *frameBuf [[buffer(3)]],
    const device void *instances [[buffer(4)]],
    const device void *instanceIndices [[buffer(5)]],
    const device void *joints [[buffer(6)]],
    const device void *materialTable [[buffer(7)]],
    const device void *materialIds [[buffer(8)]],
    const device void *lights [[buffer(9)]],
    const device void *clusterCounts [[buffer(10)]],
    const device void *clusterIndices [[buffer(11)]],
    const device void *probes [[buffer(12)]],
    const device void *localMatrices [[buffer(13)]],
    constant uint2 &limits [[buffer(14)]])
{
    if (gid >= limits.x) { return; }
    uint base = gid * 8u;
    uint indexCount = drawArgs[base];
    uint instances = drawArgs[base + 1u];
    uint indexStart = drawArgs[base + 2u];
    uint baseInstance = drawArgs[base + 4u];
    uint skinned = drawArgs[base + 5u];
    render_command cmd(icbContainer->commandBuffer, gid);
    cmd.set_render_pipeline_state(draws[gid].pipeline);
    cmd.set_vertex_buffer(draws[gid].vertices, 0);
    if (skinned != 0u) { cmd.set_vertex_buffer(draws[gid].skin, 1); }
    cmd.set_vertex_buffer(frameBuf, 2);
    cmd.set_fragment_buffer(frameBuf, 2);
    cmd.set_vertex_buffer(instances, 3);
    cmd.set_fragment_buffer(instances, 3);
    cmd.set_vertex_buffer(joints, 8);
    cmd.set_vertex_buffer(instanceIndices, 9);
    cmd.set_fragment_buffer(materialTable, 13);
    cmd.set_fragment_buffer(materialIds, 14);
    if (limits.y != 0u) {
        cmd.set_fragment_buffer(lights, 5);
        cmd.set_fragment_buffer(clusterCounts, 6);
        cmd.set_fragment_buffer(clusterIndices, 7);
        cmd.set_fragment_buffer(probes, 10);
        cmd.set_fragment_buffer(localMatrices, 12);
    }
    cmd.draw_indexed_primitives(
        primitive_type::triangle, indexCount, index_type::uint32, draws[gid].indexBuffer, indexStart * 4u,
        instances, 0, baseInstance);
}
