import FeroxAnimation
import FeroxCore
import FeroxScene
import Foundation

/// Built-in asset identifiers available without any project files.
public enum BuiltinAssets {
    public static let cube = AssetID("ferox/mesh/cube")
    public static let sphere = AssetID("ferox/mesh/sphere")
    public static let plane = AssetID("ferox/mesh/plane")
    public static let quad = AssetID("ferox/mesh/quad")
    public static let whiteTexture = AssetID("ferox/texture/white")
    public static let checkerTexture = AssetID("ferox/texture/checker")
    public static let flatNormalTexture = AssetID("ferox/texture/flat-normal")
    public static let defaultMaterial = MaterialData.default.id
}

extension AssetManager {
    /// Registers built-in meshes, textures and the default material.
    public func registerBuiltins() {
        registerMesh(.cube(), id: BuiltinAssets.cube)
        registerMesh(.sphere(), id: BuiltinAssets.sphere)
        registerMesh(.plane(size: 10, subdivisions: 1), id: BuiltinAssets.plane)
        var quad = MeshData(
            name: "Quad", positions: [Vec3(-0.5, -0.5, 0), Vec3(0.5, -0.5, 0), Vec3(0.5, 0.5, 0), Vec3(-0.5, 0.5, 0)],
            indices: [0, 1, 2, 0, 2, 3])
        quad.normals = Array(repeating: Vec3(0, 0, 1), count: 4)
        quad.uv0 = [Vec2(0, 1), Vec2(1, 1), Vec2(1, 0), Vec2(0, 0)]
        quad.generateTangents()
        registerMesh(quad, id: BuiltinAssets.quad)
        registerTexture(.solid(.white), id: BuiltinAssets.whiteTexture)
        registerTexture(.checkerboard(), id: BuiltinAssets.checkerTexture)
        registerTexture(
            ImageData(width: 1, height: 1, format: .rgba8Unorm, pixels: Data([128, 128, 255, 255])),
            id: BuiltinAssets.flatNormalTexture)
        registerMaterial(.default)
    }
}

/// Creates entity hierarchies from loaded models.
public struct ModelInstantiator {
    public let assets: AssetManager
    public let animations: AnimationLibrary?

    public init(assets: AssetManager, animations: AnimationLibrary?) {
        self.assets = assets
        self.animations = animations
    }

    /// Registers the model's meshes, materials, skeletons and clips with the asset manager
    /// and animation library. Idempotent.
    public func register(_ model: LoadedModel, id: AssetID) {
        for (i, m) in model.data.meshes.enumerated() { assets.registerMesh(m, id: meshID(id, i)) }
        for m in model.data.materials { assets.registerMaterial(m) }
        for (i, s) in model.data.skins.enumerated() { animations?.add(s.skeleton, id: skinID(id, i)) }
        for c in model.data.animations { animations?.add(c) }
    }

    public func meshID(_ model: AssetID, _ i: Int) -> AssetID { AssetID("\(model.rawValue)#mesh\(i)") }
    public func skinID(_ model: AssetID, _ i: Int) -> AssetID { AssetID("\(model.rawValue)#skin\(i)") }

    /// Instantiates the model under a new root entity.
    /// - Parameter playFirstAnimation: adds an `Animator` playing the first clip, if any.
    @discardableResult
    public func instantiate(
        _ model: LoadedModel, id: AssetID, into world: World, transform: Transform = Transform(),
        parent: Entity = .null,
        playFirstAnimation: Bool = true
    ) -> Entity {
        register(model, id: id)
        let data = model.data
        let root = world.createEntity(named: data.name, transform: transform, parent: parent)
        var entities = [Entity](repeating: .null, count: data.nodes.count)

        func make(_ n: Int, parent: Entity, depth: Int) {
            guard depth < 256, data.nodes.indices.contains(n), entities[n].isNull else { return }
            let node = data.nodes[n]
            let e = world.createEntity(named: node.name, transform: Transform(node.transform), parent: parent)
            entities[n] = e
            if let mi = node.mesh, data.meshes.indices.contains(mi) {
                let mesh = data.meshes[mi]
                let mats = mesh.submeshes.map { s in
                    data.materials.indices.contains(s.materialIndex)
                        ? data.materials[s.materialIndex].id : MaterialData.default.id
                }
                if let si = node.skin, data.skins.indices.contains(si), mesh.isSkinned {
                    world.add(SkinnedMeshRenderer(mesh: meshID(id, mi), materials: mats, skin: skinID(id, si)), to: e)
                } else {
                    world.add(MeshRenderer(mesh: meshID(id, mi), materials: mats), to: e)
                }
            }
            if let l = node.light { world.add(l, to: e) }
            if let c = node.camera { world.add(c, to: e) }
            for c in node.children { make(c, parent: e, depth: depth + 1) }
        }
        for r in data.roots { make(r, parent: root, depth: 0) }

        // Resolve skin joints to entities.
        for (n, node) in data.nodes.enumerated() {
            guard let si = node.skin, data.skins.indices.contains(si), !entities[n].isNull else { continue }
            let joints = data.skins[si].joints.map { $0 < entities.count ? entities[$0] : .null }
            world.modify(SkinnedMeshRenderer.self, entities[n]) { $0.joints = joints }
        }
        if let first = data.skins.first {
            world.add(
                SkeletonBinding(
                    skeleton: skinID(id, 0), joints: first.joints.map { $0 < entities.count ? entities[$0] : .null }),
                to: root)
        }
        if playFirstAnimation, let clip = data.animations.first {
            world.add(Animator(clip: clip.id), to: root)
        }
        return root
    }
}
