import FeroxAnimation
import FeroxAssets
import FeroxCore
import FeroxScene
import Foundation

// Scene extraction: turns the ECS world into flat, GPU-ready arrays (instances, batches,
// lights, joint palettes). This is the only place the renderer reads gameplay data, and it
// contains no Metal code, so culling, LOD, batching and sorting are unit-tested on Linux.

/// The camera a frame is rendered from.
public struct RenderCamera: Sendable {
    public var entity: Entity
    public var camera: Camera
    /// Rigid camera-to-world matrix (scale removed).
    public var world: Mat4
    public var view: Mat4
    public var position: Vec3
    public var forward: Vec3
    public var aspect: Float
    /// Unjittered projection.
    public var projection: Mat4
    public var viewProjection: Mat4

    public init(entity: Entity, camera: Camera, worldMatrix m: Mat4, aspect: Float) {
        self.entity = entity
        self.camera = camera
        let x = m.c0.xyz.normalized, y = m.c1.xyz.normalized, z = m.c2.xyz.normalized
        let rigid = Mat4(columns: Vec4(x, 0), Vec4(y, 0), Vec4(z, 0), Vec4(m.translation, 1))
        world = rigid
        view = rigid.affineInverse
        position = m.translation
        forward = -z
        self.aspect = max(aspect, 1e-4)
        projection = camera.projectionMatrix(aspect: self.aspect)
        viewProjection = projection * view
    }
}

/// A range of instances drawn with one mesh submesh and one material.
public struct DrawBatch: Sendable, Hashable {
    public var mesh: AssetID
    public var submesh: Int
    /// nil uses the default material.
    public var material: AssetID?
    /// First element in `RenderFrameData.instanceIndices` (the draw's `baseInstance`).
    public var firstInstance: Int
    public var instanceCount: Int
    public var skinned: Bool
    public var alphaTest: Bool
    public var doubleSided: Bool
    public var unlit: Bool
    /// View depth of the nearest instance (transparent sorting, front-to-back hints).
    public var depth: Float
}

/// A directional light that drives the shadow cascades and the main sky.
public struct SunLight: Sendable, Hashable {
    /// Unit vector from the scene towards the light.
    public var towardsLight: Vec3
    public var color: Vec3
    public var intensity: Float
    public var castsShadows: Bool
}

/// A reflection probe placed in the scene.
public struct RenderProbe: Sendable {
    public var entity: Entity
    public var probe: ReflectionProbe
    public var position: Vec3
}

/// One mesh instance submitted to ray tracing (one per renderer, all submeshes).
public struct RayTracingInstance: Sendable {
    public var mesh: AssetID
    public var transform: Mat4
    public var material: RTInstanceMaterial
    public var isStatic: Bool
}

/// Everything the 3D passes need for one frame.
public struct RenderFrameData {
    public var camera: RenderCamera?
    public var instances: [InstanceData] = []
    /// Instance indirection read by the vertex shaders (`instanceIndices[iid + baseInstance]`).
    public var instanceIndices: [UInt32] = []
    /// Batch index per instance for GPU culling (`UInt32.max` = not GPU-culled).
    public var instanceBatch: [UInt32] = []
    public var opaque: [DrawBatch] = []
    /// One batch per instance, sorted back to front.
    public var transparent: [DrawBatch] = []
    public var shadowCasters: [DrawBatch] = []
    public var joints: [Mat4] = []
    /// Directional lights first (sun at index 0 when present), then punctual lights.
    public var lights: [LightData] = []
    public var directionalCount = 0
    public var punctualCount = 0
    /// Indices into `lights` of the point and spot lights that request shadows, nearest to
    /// the camera first. The renderer gives slices to as many as its budget allows.
    public var shadowedLights: [Int] = []
    public var sun: SunLight?
    public var environment = Environment()
    public var probes: [RenderProbe] = []
    public var rayTracingInstances: [RayTracingInstance] = []
    public var visibleObjects = 0
    public var culledObjects = 0
    public init() {}
}

/// Options controlling extraction.
public struct ExtractionOptions: Sendable {
    /// CPU frustum culling. Disable when GPU culling runs instead, or to extract every
    /// renderer regardless of the main camera (reflection-probe capture).
    public var frustumCull = true
    public var lodBias: Float = 1
    /// Shadow casters further than this from the camera are skipped.
    public var shadowDistance: Float = 120
    public var maxPunctualLights = 1024
    public var collectRayTracingInstances = false
    /// Renders from this camera instead of the world's main camera (reflection-probe
    /// faces, render-to-texture cameras).
    public var cameraOverride: RenderCamera?
    public init() {}
}

public enum RenderSceneExtractor {
    /// Picks the enabled camera with the highest priority (ties: lowest entity index).
    public static func mainCamera(in world: World) -> (Entity, Camera)? {
        var best: (Entity, Camera)?
        world.read(Camera.self) { e, c in
            guard c.renderTarget == nil, world.isActiveInHierarchy(e) else { return }
            if let b = best, b.1.priority > c.priority || (b.1.priority == c.priority && b.0 < e) { return }
            best = (e, c)
        }
        return best
    }

    static func worldMatrix(_ world: World, _ e: Entity) -> Mat4 {
        world.get(WorldTransform.self, e)?.matrix ?? world.worldMatrix(of: e)
    }

    static func layerMask(_ world: World, _ e: Entity) -> LayerMask {
        world.get(Layer.self, e)?.mask ?? .default
    }

    struct Item {
        var mesh: AssetID
        var submesh: Int
        var material: AssetID?
        var instance: Int
        var skinned: Bool
        var alphaTest: Bool
        var doubleSided: Bool
        var unlit: Bool
        var transparent: Bool
        var castsShadows: Bool
        var visible: Bool
        var depth: Float
    }

    /// Extracts a frame from `world`. `aspect` is the output aspect ratio.
    public static func extract(world: World, assets: AssetManager, animations: AnimationLibrary?,
                               aspect: Float, options: ExtractionOptions = ExtractionOptions()) -> RenderFrameData {
        var frame = RenderFrameData()
        if let env = world.entities(with: Environment.self).first.flatMap({ world.get(Environment.self, $0) }) {
            frame.environment = env
        }
        let rc: RenderCamera
        if let override = options.cameraOverride {
            rc = override
        } else {
            guard let main = mainCamera(in: world) else { return frame }
            rc = RenderCamera(entity: main.0, camera: main.1, worldMatrix: worldMatrix(world, main.0), aspect: aspect)
        }
        let cam = rc.camera
        frame.camera = rc
        let frustum = Frustum(viewProjection: rc.viewProjection)

        // Each renderer adds at least one instance and one item; submeshes add more items.
        let rendererCount = world.count(of: MeshRenderer.self) + world.count(of: SkinnedMeshRenderer.self)
        var items: [Item] = []
        items.reserveCapacity(rendererCount)
        frame.instances.reserveCapacity(rendererCount)
        func addRenderer(_ e: Entity, mesh meshID: AssetID, materials: [AssetID], castsShadows: Bool,
                         receivesShadows: Bool, isStatic: Bool, skinned: SkinnedMeshRenderer?) {
            guard world.isActiveInHierarchy(e), cam.cullingMask.contains(layerMask(world, e)) else { return }
            let wt = world.get(WorldTransform.self, e)
            let model = wt?.matrix ?? world.worldMatrix(of: e)
            let previous = (wt?.resetHistory ?? true) ? model : (wt?.previous ?? model)

            var chosenMesh = meshID
            guard let meshHandle0 = assets.mesh(meshID), let mesh0 = meshHandle0.value else { return }
            var sphere = RenderMath.boundingSphere(mesh0.bounds, model)
            if skinned != nil { sphere.radius *= 1.5 }  // bind-pose bounds; poses can extend them
            let distance = (sphere.center - rc.position).dot(rc.forward)

            if let lod = world.get(LODGroup.self, e), !lod.levels.isEmpty {
                let ortho: Float? = cam.projection == .orthographic ? cam.orthographicSize : nil
                let h = RenderMath.screenHeightFraction(radius: sphere.radius, distance: max(distance, cam.near),
                                                        fovY: cam.fieldOfView, orthoSize: ortho)
                guard let level = lod.select(screenHeight: h, bias: options.lodBias) else {
                    frame.culledObjects += 1
                    return
                }
                chosenMesh = lod.levels[level].mesh
            }
            guard let mesh = chosenMesh == meshID ? mesh0 : assets.mesh(chosenMesh)?.value else { return }

            let inFrustum = frustum.contains(sphere)
            let shadowRelevant = castsShadows && distance - sphere.radius < options.shadowDistance
            // With CPU frustum culling disabled (GPU culling, probe capture) every instance
            // is kept; otherwise off-screen objects survive only to cast shadows or to be
            // ray traced.
            if options.frustumCull && !inFrustum && !shadowRelevant && !options.collectRayTracingInstances {
                frame.culledObjects += 1
                return
            }
            if inFrustum { frame.visibleObjects += 1 } else { frame.culledObjects += 1 }

            var inst = InstanceData(model: model, previous: previous)
            inst.bounds = Vec4(sphere.center, sphere.radius)
            inst.params.z = sphere.radius
            if let o = world.get(MaterialOverrides.self, e) {
                if let c = o.baseColor { inst.colorTint = c.vector }
                if let em = o.emissive { inst.emissiveAdd = Vec4(em.rgb, 0) }
                if let m = o.metallic { inst.params.x = min(max(m, 0), 1) }
                if let r = o.roughness { inst.params.y = min(max(r, 0), 1) }
            }
            // Read by the forward shader, which then skips every shadow lookup.
            inst.emissiveAdd.w = receivesShadows ? 0 : 1
            var isSkinned = false
            if let s = skinned, mesh.isSkinned, let skeleton = animations?.skeletons[s.skin],
               s.joints.count == skeleton.inverseBindMatrices.count, !s.joints.isEmpty {
                let inverseModel = model.inverse
                inst.params.w = Float(frame.joints.count)
                for (j, je) in s.joints.enumerated() {
                    let jm = world.isAlive(je) ? worldMatrix(world, je) : model
                    frame.joints.append(inverseModel * jm * skeleton.inverseBindMatrices[j])
                }
                isSkinned = true
            }
            let index = frame.instances.count
            frame.instances.append(inst)

            if options.collectRayTracingInstances {
                let mat = materials.first.flatMap { assets.loadedMaterial($0) } ?? .default
                var rt = RTInstanceMaterial()
                rt.albedoRoughness = Vec4(mat.baseColor.rgb, mat.roughness)
                rt.emissiveMetallic = Vec4(mat.emissive.rgb * mat.emissiveStrength, mat.metallic)
                frame.rayTracingInstances.append(
                    RayTracingInstance(mesh: chosenMesh, transform: model, material: rt, isStatic: isStatic))
            }

            let submeshes = mesh.submeshes.isEmpty
                ? [MeshData.Submesh(indexOffset: 0, indexCount: mesh.indices.count, materialIndex: 0)] : mesh.submeshes
            for (si, sub) in submeshes.enumerated() where sub.indexCount > 0 {
                let matID: AssetID? = materials.isEmpty ? nil
                    : materials[min(max(sub.materialIndex, 0), materials.count - 1)]
                let mat = matID.flatMap { assets.loadedMaterial($0) }
                items.append(Item(
                    mesh: chosenMesh, submesh: si, material: matID, instance: index, skinned: isSkinned,
                    alphaTest: mat?.alphaMode == .mask, doubleSided: mat?.doubleSided ?? false,
                    unlit: mat?.unlit ?? false, transparent: mat?.alphaMode == .blend,
                    castsShadows: shadowRelevant && mat?.alphaMode != .blend,
                    visible: inFrustum || !options.frustumCull, depth: distance))
            }
        }

        world.read(MeshRenderer.self) { e, r in
            addRenderer(e, mesh: r.mesh, materials: r.materials, castsShadows: r.castsShadows,
                        receivesShadows: r.receivesShadows, isStatic: r.isStatic, skinned: nil)
        }
        world.read(SkinnedMeshRenderer.self) { e, r in
            addRenderer(e, mesh: r.mesh, materials: r.materials, castsShadows: r.castsShadows,
                        receivesShadows: r.receivesShadows, isStatic: false, skinned: r)
        }

        buildBatches(items, into: &frame)
        extractLights(world: world, camera: rc, frustum: frustum, options: options, into: &frame)
        world.read(ReflectionProbe.self) { e, p in
            guard world.isActiveInHierarchy(e) else { return }
            frame.probes.append(RenderProbe(entity: e, probe: p, position: worldMatrix(world, e).translation))
        }
        return frame
    }

    /// Strict weak ordering by render state: material, mesh, submesh, then pipeline flags.
    static func batchOrder(_ a: Item, _ b: Item) -> Bool {
        let am = a.material?.rawValue ?? "", bm = b.material?.rawValue ?? ""
        if am != bm { return am < bm }
        if a.mesh.rawValue != b.mesh.rawValue { return a.mesh.rawValue < b.mesh.rawValue }
        if a.submesh != b.submesh { return a.submesh < b.submesh }
        return flags(a) < flags(b)
    }

    static func flags(_ a: Item) -> Int {
        (a.skinned ? 1 : 0) | (a.alphaTest ? 2 : 0) | (a.doubleSided ? 4 : 0) | (a.unlit ? 8 : 0)
    }

    static func sameBatch(_ a: Item, _ b: Item) -> Bool {
        // Skinned instances use per-instance palettes but can still share a draw; they are
        // kept separate so each skinned mesh is its own batch, which keeps culling simple.
        !a.skinned && !b.skinned && a.material == b.material && a.mesh == b.mesh && a.submesh == b.submesh
            && a.alphaTest == b.alphaTest && a.doubleSided == b.doubleSided && a.unlit == b.unlit
    }

    static func buildBatches(_ items: [Item], into frame: inout RenderFrameData) {
        frame.instanceBatch = [UInt32](repeating: .max, count: frame.instances.count)

        // Opaque: sort by state (material, mesh) to minimise binds, then group.
        let opaque = items.filter { !$0.transparent && $0.visible }.sorted(by: batchOrder)
        var current: DrawBatch?
        var currentItem: Item?
        func flush() {
            if let b = current { frame.opaque.append(b) }
            current = nil
        }
        for it in opaque {
            if let ci = currentItem, current != nil, sameBatch(ci, it) {
                current?.instanceCount += 1
                if let d = current?.depth { current?.depth = min(d, it.depth) }
            } else {
                flush()
                current = DrawBatch(mesh: it.mesh, submesh: it.submesh, material: it.material,
                                    firstInstance: frame.instanceIndices.count, instanceCount: 1, skinned: it.skinned,
                                    alphaTest: it.alphaTest, doubleSided: it.doubleSided, unlit: it.unlit, depth: it.depth)
            }
            frame.instanceIndices.append(UInt32(it.instance))
            // An instance with several submeshes appears in several batches; GPU culling then
            // keeps only the first batch's association and the CPU path draws the others.
            if frame.instanceBatch[it.instance] == .max { frame.instanceBatch[it.instance] = UInt32(frame.opaque.count) }
            currentItem = it
        }
        flush()

        // Transparent: back to front, one draw each (order matters for blending).
        let transparent = items.filter { $0.transparent && $0.visible }.sorted { $0.depth > $1.depth }
        for it in transparent {
            frame.transparent.append(DrawBatch(
                mesh: it.mesh, submesh: it.submesh, material: it.material, firstInstance: frame.instanceIndices.count,
                instanceCount: 1, skinned: it.skinned, alphaTest: false, doubleSided: it.doubleSided, unlit: it.unlit,
                depth: it.depth))
            frame.instanceIndices.append(UInt32(it.instance))
        }

        // Shadow casters: all relevant items regardless of camera visibility.
        let casters = items.filter(\.castsShadows).sorted(by: batchOrder)
        current = nil
        currentItem = nil
        for it in casters {
            if let ci = currentItem, current != nil, sameBatch(ci, it) {
                current?.instanceCount += 1
            } else {
                if let b = current { frame.shadowCasters.append(b) }
                current = DrawBatch(mesh: it.mesh, submesh: it.submesh, material: it.material,
                                    firstInstance: frame.instanceIndices.count, instanceCount: 1, skinned: it.skinned,
                                    alphaTest: it.alphaTest, doubleSided: it.doubleSided, unlit: false, depth: it.depth)
            }
            frame.instanceIndices.append(UInt32(it.instance))
            currentItem = it
        }
        if let b = current { frame.shadowCasters.append(b) }
    }

    static func extractLights(world: World, camera: RenderCamera, frustum: Frustum, options: ExtractionOptions,
                              into frame: inout RenderFrameData) {
        var directional: [(Light, Vec3)] = []
        // Punctual lights with whether each requests a shadow.
        var punctual: [(data: LightData, shadowed: Bool)] = []
        world.read(Light.self) { e, l in
            guard !l.is2D, l.intensity > 0, world.isActiveInHierarchy(e),
                  camera.camera.cullingMask.contains(layerMask(world, e)) else { return }
            let m = worldMatrix(world, e)
            let forward = m.transformDirection(.forward).normalized
            switch l.type {
            case .directional:
                directional.append((l, forward))
            case .point, .spot:
                let p = m.translation
                guard frustum.contains(Sphere(center: p, radius: l.range)) else { return }
                var d = LightData()
                d.positionRange = Vec4(p, max(l.range, 1e-3))
                d.color = Vec4(l.color.rgb * l.intensity, l.type == .point ? 1 : 2)
                let outer = min(max(l.outerConeAngle, 0.001), .pi / 2 - 0.001)
                let inner = min(max(l.innerConeAngle, 0), outer - 0.0005)
                d.direction = Vec4(forward, cos(outer))
                d.extra = Vec4(cos(inner), -1, 0, 0)  // shadow slice assigned by the renderer
                punctual.append((d, l.castsShadows))
            }
        }
        // The sun: the first shadow-casting directional light, else the brightest one.
        if let si = directional.firstIndex(where: { $0.0.castsShadows })
            ?? directional.indices.max(by: { directional[$0].0.intensity < directional[$1].0.intensity }) {
            directional.swapAt(0, si)
            let (l, fwd) = directional[0]
            frame.sun = SunLight(towardsLight: -fwd, color: l.color.rgb, intensity: l.intensity, castsShadows: l.castsShadows)
        }
        for (l, fwd) in directional {
            var d = LightData()
            d.color = Vec4(l.color.rgb * l.intensity, 0)
            d.direction = Vec4(fwd, 0)
            frame.lights.append(d)
        }
        frame.directionalCount = directional.count
        func distance2(_ d: LightData) -> Float { (d.positionRange.xyz - camera.position).lengthSquared }
        if punctual.count > options.maxPunctualLights {
            // Keep the nearest lights; the rest are dropped this frame.
            punctual.sort { distance2($0.data) < distance2($1.data) }
            punctual.removeLast(punctual.count - options.maxPunctualLights)
        }
        let first = frame.lights.count
        frame.lights.append(contentsOf: punctual.map(\.data))
        frame.punctualCount = punctual.count
        // Each distance is computed once; equal distances keep ascending index order.
        let shadowed = punctual.indices.filter { punctual[$0].shadowed }
            .map { (index: $0, distance: distance2(punctual[$0].data)) }
        frame.shadowedLights = shadowed
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }
            .map { first + $0.index }
    }
}
