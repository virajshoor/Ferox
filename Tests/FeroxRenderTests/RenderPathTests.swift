import FeroxAssets
import FeroxCore
import FeroxMath
import FeroxScene
import Foundation
import XCTest

@testable import FeroxRender

final class GPUFrameClockTests: XCTestCase {
    func testScenePlusPostBecomesTheLastSample() {
        let clock = GPUFrameClock(framesInFlight: 2)
        XCTAssertNil(clock.lastMilliseconds())
        clock.recordScene(slot: 1, milliseconds: 4)
        XCTAssertEqual(clock.recordPost(slot: 1, postMilliseconds: 1.5), 5.5, accuracy: 1e-9)
        XCTAssertEqual(clock.lastMilliseconds() ?? -1, 5.5, accuracy: 1e-9)
        clock.recordScene(slot: 0, milliseconds: 0)
        XCTAssertEqual(clock.recordPost(slot: 0, postMilliseconds: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(clock.lastMilliseconds() ?? -1, 5.5, accuracy: 1e-9)
    }

    func testUnknownSlotDoesNotChangeTheLastSample() {
        let clock = GPUFrameClock(framesInFlight: 1)
        clock.recordScene(slot: 0, milliseconds: 2)
        XCTAssertEqual(clock.recordPost(slot: 0, postMilliseconds: 1), 3, accuracy: 1e-9)
        clock.recordScene(slot: 4, milliseconds: 9)
        XCTAssertEqual(clock.recordPost(slot: 4, postMilliseconds: 9), 0, accuracy: 1e-9)
        XCTAssertEqual(clock.lastMilliseconds() ?? -1, 3, accuracy: 1e-9)
    }
}

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
    private func overlaps(_ a: HeapPlacement, _ b: HeapPlacement) -> Bool {
        let aEnd = a.offset + a.size
        let bEnd = b.offset + b.size
        return !(aEnd <= b.offset || bEnd <= a.offset)
    }

    func testLifetimesAliasScratchesAndKeepThePingPongDistinct() {
        XCTAssertFalse(TransientHeapPlan.msaaAttachmentsAreMemoryless)
        var features = HeapFeatures()
        features.geometryPrepass = true
        features.ambientOcclusion = true
        features.bloom = true
        features.depthOfField = true
        features.motionBlur = true
        features.smaa = true
        features.msaa = true
        let lives = Dictionary(uniqueKeysWithValues: TransientHeapPlan.lifetimes(features).map { ($0.resource, $0) })
        XCTAssertFalse(TransientHeapPlan.overlaps(lives[.ambientOcclusion]!, lives[.bloom]!))
        XCTAssertFalse(TransientHeapPlan.overlaps(lives[.normal]!, lives[.hdr]!))
        XCTAssertTrue(TransientHeapPlan.overlaps(lives[.ldrA]!, lives[.ldrB]!))
        XCTAssertTrue(TransientHeapPlan.overlaps(lives[.smaaEdges]!, lives[.smaaWeights]!))
        XCTAssertTrue(TransientHeapPlan.overlaps(lives[.depth]!, lives[.hdr]!))
        XCTAssertFalse(TransientHeapPlan.overlaps(lives[.hdrMSAA]!, lives[.bloom]!))

        let footprints = TransientHeapPlan.requests(
            renderWidth: 128, renderHeight: 64, outputWidth: 256, outputHeight: 128, features: features,
            msaaSamples: 4
        ).map {
            TransientFootprint(resource: $0.resource, byteSize: max($0.width * $0.height * 8, 256), alignment: 256)
        }
        let layout = TransientHeapPlan.layout(footprints: footprints, features: features)
        let ldrA = layout.placement(of: .ldrA)!
        let ldrB = layout.placement(of: .ldrB)!
        let depth = layout.placement(of: .depth)!
        let hdr = layout.placement(of: .hdr)!
        let edges = layout.placement(of: .smaaEdges)!
        let weights = layout.placement(of: .smaaWeights)!
        XCTAssertFalse(overlaps(ldrA, ldrB))
        XCTAssertFalse(overlaps(depth, hdr))
        XCTAssertFalse(overlaps(edges, weights))
        XCTAssertFalse(layout.barriers.isEmpty)
        XCTAssertTrue(layout.barriers.contains { $0.destination == .bloom || $0.destination == .depthOfField })
        let sum = footprints.reduce(0) { $0 + $1.byteSize }
        XCTAssertLessThan(layout.byteSize, sum)
        XCTAssertTrue(layout.placements.allSatisfy { $0.offset % 256 == 0 })
        XCTAssertEqual(TransientHeapPlan.resource(forLabel: "Ferox.Bloom"), .bloom)
        XCTAssertEqual(
            TransientHeapPlan.requests(
                renderWidth: 64, renderHeight: 64, outputWidth: 128, outputHeight: 128,
                features: {
                    var f = features
                    f.temporal = true
                    return f
                }(), msaaSamples: 1
            ).first { $0.resource == .depthOfField }?.width, 128)
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
        XCTAssertEqual(
            DrawPolicy.submission(indirectCommandBuffers: true, gpuIndirectDraws: true), .immediate)
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

    func testOffscreenResolutionIsPerCamera() {
        var screen = Camera.perspective()
        XCTAssertEqual(CameraTargets.resolution(screen, screenWidth: 1920, screenHeight: 1080).width, 1920)
        XCTAssertEqual(CameraTargets.resolution(screen, screenWidth: 1920, screenHeight: 1080).height, 1080)
        screen.targetSize = CameraTargetSize(width: 320, height: 180)
        let sized = CameraTargets.resolution(screen, screenWidth: 1920, screenHeight: 1080)
        XCTAssertEqual(sized.width, 320)
        XCTAssertEqual(sized.height, 180)
        screen.targetSize = CameraTargetSize(width: 0, height: -4)
        XCTAssertEqual(CameraTargets.resolution(screen, screenWidth: 10, screenHeight: 10).width, 1)
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

    func testInstancePickReadbackKeepsTheLatestSerial() {
        var readback = InstancePickReadback()
        let first = readback.request(x: 3, y: 4)
        let second = readback.request(x: -2, y: 9)
        XCTAssertEqual(first.serial, 1)
        XCTAssertEqual(second.x, 0)
        XCTAssertGreaterThan(second.serial, first.serial)
        readback.complete(serial: first.serial, word: 7)
        XCTAssertNil(readback.sample)
        readback.complete(serial: second.serial, word: 0)
        let world = World()
        let entity = world.createEntity()
        XCTAssertEqual(readback.entity(serial: second.serial, map: InstancePickMap(entities: [entity])), entity)
        let pixel = InstancePickStaging.renderPixel(
            viewX: 10, viewY: 20, viewWidth: 100, viewHeight: 50, renderWidth: 200, renderHeight: 100)
        XCTAssertEqual(pixel.x, 20)
        XCTAssertEqual(pixel.y, 40)
        XCTAssertEqual(InstancePickStaging.byteCount, 256)
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
            let assets = AssetManager(database: nil)
            let mesh = AssetID("pick.cube")
            assets.registerMesh(.cube(), id: mesh)
            let renderer = try Renderer(assets: assets)
            XCTAssertTrue(renderer.shaders.failures.isEmpty, "\(renderer.shaders.failures)")
            XCTAssertEqual(renderer.shaders.module(of: "prepassPickFragment"), "Mesh")
            XCTAssertTrue(renderer.metalFXProbe.attempted)
            XCTAssertFalse(renderer.metalFXProbe.depthFormat.isEmpty)
            let world = World()
            let cameraEntity = world.createEntity(
                named: "Camera",
                transform: Transform(position: Vec3(0, 0, 4), rotation: .lookRotation(forward: Vec3(0, 0, -1))))
            world.add(Camera.perspective(), to: cameraEntity)
            let cube = world.createEntity(named: "Cube")
            world.add(MeshRenderer(mesh: mesh), to: cube)
            renderer.scheduleInstancePick(x: 32, y: 32, serial: 1, viewWidth: 64, viewHeight: 64)
            XCTAssertNotNil(renderer.renderOffscreen(world: world, width: 64, height: 64))
            let sample = renderer.takeInstancePick()
            XCTAssertEqual(sample?.serial, 1)
            XCTAssertEqual(sample?.instance, 0)
            XCTAssertEqual(sample?.entities.first, cube)

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
