import Ferox
import FeroxAssets
import FeroxCore
import FeroxMath
import FeroxScene
/// GPU-culling plan: every submesh is visible independently, and indirect draws stay aligned.
import XCTest

@testable import FeroxRender

final class CullingPlanTests: XCTestCase {
    func batch(_ first: Int, _ count: Int, submesh: Int = 0) -> DrawBatch {
        DrawBatch(
            mesh: AssetID("m"), submesh: submesh, material: nil, firstInstance: first, instanceCount: count,
            skinned: false, alphaTest: false, doubleSided: false, unlit: false, depth: 0)
    }

    func testStrideKeepsEveryBatchAligned() {
        XCTAssertEqual(IndirectDrawLayout.strideBytes, 32)
        XCTAssertEqual(IndirectDrawLayout.words, 8)
        for i in 0..<16 {
            XCTAssertTrue(IndirectDrawLayout.isValidGPUOffset(IndirectDrawLayout.byteOffset(ofBatch: i)))
        }
        // The old 20-byte stride failed this for every batch after the first even one.
        XCTAssertFalse(IndirectDrawLayout.isValidGPUOffset(20))
    }

    func testEverySubmeshIsAMembership() {
        let indices: [UInt32] = [0, 0]
        let batches = [batch(0, 1, submesh: 0), batch(1, 1, submesh: 1)]
        let plan = CullingPlan.make(batches: batches, instanceIndices: indices)
        XCTAssertEqual(plan.cullable, [true, true])
        XCTAssertEqual(
            plan.memberships,
            [
                BatchMembership(instance: 0, batch: 0),
                BatchMembership(instance: 0, batch: 1),
            ])
        XCTAssertEqual(plan.drawArgs.count, 16)
        XCTAssertEqual(plan.drawArgs[IndirectDrawLayout.baseInstance], 0)
        XCTAssertEqual(plan.drawArgs[IndirectDrawLayout.words + IndirectDrawLayout.baseInstance], 1)
        XCTAssertEqual(plan.drawArgs[IndirectDrawLayout.instanceCount], 0)
    }

    func testEmptyBatchIsNotCullable() {
        let plan = CullingPlan.make(batches: [batch(0, 0)], instanceIndices: [])
        XCTAssertEqual(plan.cullable, [false])
        XCTAssertTrue(plan.memberships.isEmpty)
    }

    func testBatchSphereReachesALocalLight() {
        var instances = [InstanceData(), InstanceData()]
        instances[0].bounds = Vec4(0, 0, 0, 1)
        instances[1].bounds = Vec4(10, 0, 0, 1)
        let batch = batch(0, 2)
        let sphere = BatchCulling.sphere(batch: batch, instanceIndices: [0, 1], instances: instances)
        XCTAssertNotNil(sphere)
        XCTAssertTrue(BatchCulling.reaches(sphere: sphere!, lightPosition: Vec3(0, 0, 0), lightRange: 0.5))
        XCTAssertFalse(BatchCulling.reaches(sphere: Vec4(100, 0, 0, 1), lightPosition: .zero, lightRange: 2))
    }

    func testDiscreteGPUsStageTextureUploads() {
        XCTAssertEqual(GPUTextureUpload.path(unifiedMemory: true), .sharedReplace)
        XCTAssertEqual(GPUTextureUpload.path(unifiedMemory: false), .stagingBlitToPrivate)
    }

    func testCullingShaderDeclaresReadAccessAndAlignedStride() throws {
        let source = try shaderSource("Culling.metal")
        XCTAssertTrue(source.contains("texture2d<float, access::read> hiz"))
        XCTAssertTrue(source.contains("DRAW_ARGS_STRIDE 8u"))
        XCTAssertTrue(source.contains("kernel void expandVisibleDraws"))
        XCTAssertFalse(source.contains("DRAW_ARGS_STRIDE 5u"))
    }

    func shaderSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/FeroxRender/Shaders/\(name)"), encoding: .utf8)
    }
}

final class MultiSubmeshExtractionTests: XCTestCase {
    func testTwoSubmeshesStayInSeparateCullableBatches() {
        Engine.registerBuiltinComponents()
        let world = World()
        let assets = AssetManager(database: nil)
        var mesh = MeshData.cube()
        let count = mesh.indices.count
        mesh.submeshes = [
            MeshData.Submesh(indexOffset: 0, indexCount: count / 2, materialIndex: 0),
            MeshData.Submesh(indexOffset: count / 2, indexCount: count - count / 2, materialIndex: 1),
        ]
        let id = AssetID("test.two")
        assets.registerMesh(mesh, id: id)
        let cam = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 0, 5)))
        world.add(Camera.perspective(), to: cam)
        let cube = world.createEntity(named: "Cube")
        world.add(MeshRenderer(mesh: id, materials: [AssetID("a"), AssetID("b")]), to: cube)
        TransformSystem.update(world)
        var options = ExtractionOptions()
        options.frustumCull = false
        let frame = RenderSceneExtractor.extract(
            world: world, assets: assets, animations: nil, aspect: 1, options: options)
        XCTAssertEqual(frame.opaque.count, 2)
        XCTAssertEqual(frame.opaque.map(\.submesh), [0, 1])
        let plan = CullingPlan.make(batches: frame.opaque, instanceIndices: frame.instanceIndices)
        XCTAssertEqual(plan.cullable, [true, true])
        XCTAssertEqual(Set(plan.memberships.map(\.batch)), [0, 1])
        XCTAssertEqual(Set(plan.memberships.map(\.instance)), [0])
    }
}
