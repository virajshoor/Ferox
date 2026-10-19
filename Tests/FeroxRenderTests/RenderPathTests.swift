import FeroxAssets
import FeroxCore
import FeroxMath
import FeroxScene
import Foundation
import XCTest

@testable import FeroxRender

final class FramePathTests: XCTestCase {
    func testOpaqueGeometryNeedsAPrepass() {
        XCTAssertTrue(
            FramePath.needsGeometryPrepass(
                opaqueCount: 1, screenSpaceAO: false, temporal: false, motionBlur: false, rayTracing: false))
        XCTAssertFalse(
            FramePath.needsGeometryPrepass(
                opaqueCount: 0, screenSpaceAO: false, temporal: false, motionBlur: false, rayTracing: false))
        XCTAssertTrue(
            FramePath.needsGeometryPrepass(
                opaqueCount: 0, screenSpaceAO: true, temporal: false, motionBlur: false, rayTracing: false))
    }

    func testSpritesUseLDROnlyWhenTheHDRChainIsIdle() {
        XCTAssertTrue(
            FramePath.spritesUseLDR(
                opaqueCount: 0, transparentCount: 0, screenSpaceAO: false, temporal: false, motionBlur: false,
                rayTracing: false, bloom: false, depthOfField: false, toneMap: false, spriteMask: false,
                debugGeometry: false))
        XCTAssertFalse(
            FramePath.spritesUseLDR(
                opaqueCount: 0, transparentCount: 0, screenSpaceAO: false, temporal: false, motionBlur: false,
                rayTracing: false, bloom: false, depthOfField: false, toneMap: true, spriteMask: false,
                debugGeometry: false))
        XCTAssertFalse(
            FramePath.spritesUseLDR(
                opaqueCount: 0, transparentCount: 0, screenSpaceAO: false, temporal: false, motionBlur: false,
                rayTracing: false, bloom: false, depthOfField: false, toneMap: false, spriteMask: true,
                debugGeometry: false))
    }
}

final class TransientHeapPlanTests: XCTestCase {
    func testPostScratchAliasesAndLDRTargetsDoNot() {
        XCTAssertFalse(TransientHeapPlan.msaaAttachmentsAreMemoryless)
        let groups = TransientHeapPlan.aliasGroups(ambientOcclusion: true, bloom: true, depthOfField: true)
        XCTAssertTrue(TransientHeapPlan.mayAlias(.ambientOcclusion, .bloom, groups: groups))
        XCTAssertTrue(TransientHeapPlan.mayAlias(.bloom, .depthOfField, groups: groups))
        XCTAssertFalse(TransientHeapPlan.mayAlias(.ldrA, .ldrB, groups: groups))
        XCTAssertFalse(TransientHeapPlan.mayAlias(.hdr, .ambientOcclusion, groups: groups))
        let alone = TransientHeapPlan.aliasGroups(ambientOcclusion: true, bloom: false, depthOfField: false)
        XCTAssertFalse(TransientHeapPlan.mayAlias(.ambientOcclusion, .bloom, groups: alone))
    }
}

final class ShaderPolicyTests: XCTestCase {
    func testHotReloadBeatsAMetallib() {
        XCTAssertEqual(
            ShaderSourcePolicy.resolve(shaderDirectorySet: true, metallibPresent: true), .hotReloadDirectory)
        XCTAssertEqual(
            ShaderSourcePolicy.resolve(shaderDirectorySet: false, metallibPresent: true), .compiledMetallib)
        XCTAssertEqual(ShaderSourcePolicy.resolve(shaderDirectorySet: false, metallibPresent: false), .runtimeSource)
    }

    func testPrewarmCoversShadowAndMaterialPermutations() {
        let keys = PipelinePrewarm.keys(clusters: true, samples: 4, materialArguments: true)
        XCTAssertEqual(keys.count, 12)
        let shadows = keys.filter { $0.pass == "shadow" }
        XCTAssertEqual(shadows.count, 4)
        XCTAssertTrue(shadows.allSatisfy { $0.samples == 1 && !$0.materialArguments })
        let forward = keys.filter { $0.pass == "forward" }
        XCTAssertEqual(forward.count, 4)
        XCTAssertTrue(forward.allSatisfy { $0.samples == 4 && $0.materialArguments && $0.clusters })
        XCTAssertTrue(keys.contains { $0.pass == "prepass" && $0.skinning && $0.unlit })
    }
}

final class DrawPolicyTests: XCTestCase {
    func testTierAndVertexIdentity() {
        XCTAssertFalse(DrawPolicy.useMaterialArgumentBuffers(argumentBuffersTier: 1))
        XCTAssertTrue(DrawPolicy.useMaterialArgumentBuffers(argumentBuffersTier: 2))
        XCTAssertEqual(DrawPolicy.submission(indirectCommandBuffers: true), .indirectCommandBuffer)
        XCTAssertEqual(DrawPolicy.submission(indirectCommandBuffers: false), .immediate)
        let box = NSObject()
        let other = NSObject()
        let id = ObjectIdentifier(box)
        XCTAssertTrue(DrawPolicy.shouldBindVertexBuffer(previous: nil, next: id))
        XCTAssertFalse(DrawPolicy.shouldBindVertexBuffer(previous: id, next: id))
        XCTAssertTrue(DrawPolicy.shouldBindVertexBuffer(previous: id, next: ObjectIdentifier(other)))
    }

    func testMaterialSlotsStayWithTheirInstanceRange() {
        let plan = MaterialTablePlan.make(
            batches: [("a", 0, 2), ("b", 2, 1), ("a", 3, 1)], indexCount: 4)
        XCTAssertEqual(plan.keys, ["a", "b"])
        XCTAssertEqual(plan.slots, [0, 0, 1, 0])
        let empty = MaterialTablePlan.make(batches: [], indexCount: 0)
        XCTAssertEqual(empty.keys, [""])
        let skipped = MaterialTablePlan.make(batches: [("z", 8, 2)], indexCount: 2)
        XCTAssertEqual(skipped.slots, [0, 0])
        XCTAssertEqual(skipped.keys, [""])
    }
}

final class MeshVertexWriterTests: XCTestCase {
    func testInterleavedDefaultsAndSkinWords() {
        var mesh = MeshData(name: "v", positions: [Vec3(1, 2, 3)], indices: [0, 0, 0])
        mesh.uv0 = [Vec2(0.25, 0.5)]
        XCTAssertEqual(MeshVertexWriter.floatsPerVertex, 18)
        XCTAssertEqual(MeshVertexWriter.interleavedByteCount(vertexCount: 1), MeshVertexLayout.stride)
        var floats = [Float](repeating: -1, count: 18)
        floats.withUnsafeMutableBytes { raw in
            MeshVertexWriter.writeInterleaved(mesh, to: raw.baseAddress!)
        }
        XCTAssertEqual(floats[0], 1)
        XCTAssertEqual(floats[1], 2)
        XCTAssertEqual(floats[2], 3)
        XCTAssertEqual(floats[4], 1)
        XCTAssertEqual(floats[10], 0.25)
        XCTAssertEqual(floats[14], 1)

        mesh.joints = [SIMD4<UInt16>(1, 2, 3, 4)]
        mesh.weights = [Vec4(1, 1, 0, 0)]
        XCTAssertEqual(MeshVertexWriter.skinByteCount(vertexCount: 1), MeshVertexLayout.skinStride)
        var words = [UInt32](repeating: 0, count: 6)
        words.withUnsafeMutableBytes { raw in
            MeshVertexWriter.writeSkin(mesh, to: raw.baseAddress!)
        }
        XCTAssertEqual(words[0], 1 | (2 << 16))
        XCTAssertEqual(words[1], 3 | (4 << 16))
        XCTAssertEqual(Float(bitPattern: words[2]), 0.5, accuracy: 1e-5)
        XCTAssertEqual(Float(bitPattern: words[3]), 0.5, accuracy: 1e-5)
    }
}

final class MeshResidencyPlannerTests: XCTestCase {
    func testIdleThenLeastRecentUnderBudget() {
        let residents = [
            ResidentMesh(key: "idle", byteCount: 100, lastUsedFrame: 0),
            ResidentMesh(key: "old", byteCount: 50, lastUsedFrame: 5),
            ResidentMesh(key: "now", byteCount: 80, lastUsedFrame: 10),
        ]
        let dropped = MeshResidencyPlanner.victims(
            residents: residents, frame: 10, maxIdleFrames: 3, budgetBytes: 100)
        XCTAssertEqual(dropped, ["idle", "old"])
        let kept = MeshResidencyPlanner.victims(
            residents: [ResidentMesh(key: "big", byteCount: 500, lastUsedFrame: 10)],
            frame: 10, maxIdleFrames: 3, budgetBytes: 10)
        XCTAssertTrue(kept.isEmpty)
    }
}

final class MetalFXMappingTests: XCTestCase {
    func testMotionScaleAndJitterPixels() {
        let mapping = MetalFXTemporalMapping.make(renderWidth: 200, renderHeight: 100, jitterNDC: Vec2(1, -1))
        XCTAssertEqual(mapping.motionScaleX, -200)
        XCTAssertEqual(mapping.motionScaleY, -100)
        XCTAssertEqual(mapping.jitterOffsetX, 100)
        XCTAssertEqual(mapping.jitterOffsetY, 50)
        let skipped = MetalFXProbeResult.notAttempted(reason: "no device")
        XCTAssertFalse(skipped.attempted)
        XCTAssertEqual(skipped.depthFormat, "depth32Float_stencil8")
        XCTAssertEqual(skipped.unavailableReason, "no device")
    }
}

final class CameraTargetSelectionTests: XCTestCase {
    func testOffscreenCamerasSortByPriorityAndSkipTheScreen() {
        let world = World()
        let screen = world.createEntity(named: "Screen")
        world.add(Camera.perspective(), to: screen)
        let low = world.createEntity(named: "Low")
        var lowCamera = Camera.perspective()
        lowCamera.priority = 1
        lowCamera.renderTarget = AssetID("low")
        world.add(lowCamera, to: low)
        let high = world.createEntity(named: "High")
        var highCamera = Camera.perspective()
        highCamera.priority = 4
        highCamera.renderTarget = AssetID("high")
        world.add(highCamera, to: high)
        let hiddenParent = world.createEntity(named: "Hidden")
        world.add(Disabled(), to: hiddenParent)
        let hidden = world.createEntity(named: "Child", parent: hiddenParent)
        var hiddenCamera = Camera.perspective()
        hiddenCamera.priority = 9
        hiddenCamera.renderTarget = AssetID("hidden")
        world.add(hiddenCamera, to: hidden)
        let found = CameraTargets.offscreen(in: world)
        XCTAssertEqual(found.map(\.target.rawValue), ["high", "low"])
    }
}

final class MeshPickingTests: XCTestCase {
    func testFrontFaceHitAndInstanceMap() {
        let mesh = MeshData(
            name: "tri",
            positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
            indices: [0, 1, 2])
        let hit = MeshRaycast.nearest(
            mesh: mesh, model: .identity, ray: Ray(origin: Vec3(0.2, 0.2, 2), direction: Vec3(0, 0, -1)))
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.t, 2, accuracy: 1e-4)
        XCTAssertGreaterThan(hit!.normal.z, 0.9)
        let back = MeshRaycast.nearest(
            mesh: mesh, model: .identity, ray: Ray(origin: Vec3(0.2, 0.2, -1), direction: Vec3(0, 0, 1)))
        XCTAssertNil(back)
        let miss = MeshRaycast.nearest(
            mesh: mesh, model: .identity, ray: Ray(origin: Vec3(5, 5, 2), direction: Vec3(0, 0, -1)))
        XCTAssertNil(miss)

        let world = World()
        let entity = world.createEntity(named: "Picked")
        let map = InstancePickMap(entities: [entity])
        XCTAssertEqual(map.entity(forInstance: 0), entity)
        XCTAssertNil(map.entity(forInstance: InstancePickMap.miss))
        XCTAssertNil(map.entity(forInstance: 4))
    }

    func testShadersDeclareTheNewPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mesh = try String(contentsOf: root.appendingPathComponent("Sources/FeroxRender/Shaders/Mesh.metal"))
        let common = try String(contentsOf: root.appendingPathComponent("Sources/FeroxRender/Shaders/Common.metal"))
        XCTAssertTrue(mesh.contains("fragment PickOut prepassPickFragment"))
        XCTAssertTrue(mesh.contains("o.materialSlot = iid"))
        XCTAssertTrue(common.contains("struct MaterialRecord"))
        XCTAssertTrue(common.contains("BUF_MATERIAL_TABLE 13"))
        XCTAssertTrue(common.contains("function_constant(5)"))
    }
}

#if canImport(Metal)
    import Metal

    /// Builds the real renderer on the macOS CI GPU. Skips only when the process has no Metal device.
    final class MetalDeviceTests: XCTestCase {
        func testRendererCompilesShadersAndProbesMetalFX() throws {
            guard MTLCreateSystemDefaultDevice() != nil else {
                throw XCTSkip(
                    "No Metal device in this process. Renderer construction and shader compilation need a GPU.")
            }
            let renderer = try Renderer(assets: AssetManager(database: nil))
            XCTAssertTrue(renderer.shaders.failures.isEmpty, "\(renderer.shaders.failures)")
            XCTAssertEqual(renderer.shaders.module(of: "prepassPickFragment"), "Mesh")
            XCTAssertTrue(renderer.metalFXProbe.attempted)
            XCTAssertFalse(renderer.metalFXProbe.depthFormat.isEmpty)
            if renderer.device.supportsFamily(.metal3) {
                let desc = MTLIndirectCommandBufferDescriptor()
                desc.commandTypes = [.drawIndexed]
                desc.inheritBuffers = false
                desc.inheritPipelineState = false
                desc.maxVertexBufferBindCount = 10
                desc.maxFragmentBufferBindCount = 15
                let icb = renderer.device.makeIndirectCommandBuffer(descriptor: desc, maxCommandCount: 1, options: [])
                XCTAssertNotNil(icb)
            }
        }
    }
#endif
