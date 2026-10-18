import Foundation
import FeroxCore

// Render-facing component *data*. These live in FeroxScene (not FeroxRender) so that
// scenes can be authored, serialized and tested without Metal; the renderer reads them.

public enum ProjectionMode: String, Codable, Sendable, CaseIterable { case perspective, orthographic }

/// A camera. The active camera is the enabled one with the highest `priority`.
public struct Camera: Component, Codable, Hashable, Sendable {
    public var projection: ProjectionMode = .perspective
    /// Vertical field of view in radians (perspective).
    public var fieldOfView: Float = 60 * .pi / 180
    /// Half-height of the view volume in world units (orthographic).
    public var orthographicSize: Float = 5
    public var near: Float = 0.1
    public var far: Float = 1000
    public var priority: Int = 0
    public var clearColor: Color = Color(0.02, 0.02, 0.025)
    /// Normalised viewport rectangle (for split-screen / picture-in-picture).
    public var viewport: Rect = .unit
    /// Layers rendered by this camera.
    public var cullingMask: LayerMask = .all
    /// Pixel-perfect 2D: snaps the camera to whole texels at `pixelsPerUnit`.
    public var pixelPerfect: Bool = false
    public var pixelsPerUnit: Float = 16
    /// Optional render-target asset; nil renders to the screen.
    public var renderTarget: AssetID?
    /// Physical camera exposure in EV100 (used when auto exposure is off).
    public var exposureEV100: Float = 0

    public init() {}
    public static func perspective(fov degrees: Float = 60, near: Float = 0.1, far: Float = 1000) -> Camera {
        var c = Camera()
        c.fieldOfView = degrees * .pi / 180
        c.near = near
        c.far = far
        return c
    }
    public static func orthographic(size: Float, near: Float = -100, far: Float = 100) -> Camera {
        var c = Camera()
        c.projection = .orthographic
        c.orthographicSize = size
        c.near = near
        c.far = far
        return c
    }

    /// Projection matrix (reverse-Z) for an aspect ratio, optionally jittered by `jitter`
    /// in clip-space units (2 / renderWidth per pixel).
    public func projectionMatrix(aspect: Float, jitter: Vec2 = .zero) -> Mat4 {
        var p: Mat4
        switch projection {
        case .perspective:
            p = .perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far)
        case .orthographic:
            let h = orthographicSize, w = h * aspect
            p = .orthographic(left: -w, right: w, bottom: -h, top: h, near: near, far: far)
        }
        if jitter != .zero {
            // Offset clip-space x/y by jitter * w; works for both projections.
            p.c2.x += projection == .perspective ? -jitter.x : 0
            p.c2.y += projection == .perspective ? -jitter.y : 0
            if projection == .orthographic {
                p.c3.x += jitter.x
                p.c3.y += jitter.y
            }
        }
        return p
    }

    /// World-space ray through `point`, given in normalised viewport coordinates (0...1, top-left
    /// origin), for a camera whose world matrix is `cameraToWorld`. Works for both projections.
    public func ray(through point: Vec2, aspect: Float, cameraToWorld: Mat4) -> Ray {
        let unproject = cameraToWorld * projectionMatrix(aspect: aspect).inverse
        let x = point.x * 2 - 1, y = 1 - point.y * 2
        // Reverse-Z: NDC depth 1 is the near plane. 0.5 stays finite even with an infinite far plane.
        let near = unproject.transformPoint(Vec3(x, y, 1))
        let mid = unproject.transformPoint(Vec3(x, y, 0.5))
        return Ray(origin: near, direction: mid - near)
    }
}

public enum LightType: String, Codable, Sendable, CaseIterable { case directional, point, spot }

/// A punctual light. Intensity units: lux for directional, candela for point/spot (as glTF
/// KHR_lights_punctual), pre-exposed by the camera.
public struct Light: Component, Codable, Hashable, Sendable {
    public var type: LightType = .point
    public var color: Color = .white
    public var intensity: Float = 10
    /// Attenuation range in world units (point/spot); lights have zero contribution beyond.
    public var range: Float = 10
    /// Spot cone angles in radians.
    public var innerConeAngle: Float = 0.3
    public var outerConeAngle: Float = 0.5
    public var castsShadows: Bool = false
    /// Contributes to 2D lighting instead of 3D.
    public var is2D: Bool = false
    public init(type: LightType = .point, color: Color = .white, intensity: Float = 10, range: Float = 10) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = range
    }
    public static func directional(_ color: Color = .white, intensity: Float = 3, shadows: Bool = true) -> Light {
        var l = Light(type: .directional, color: color, intensity: intensity, range: 0)
        l.castsShadows = shadows
        return l
    }
}

/// Renders a mesh asset with one material per submesh.
public struct MeshRenderer: Component, Codable, Hashable, Sendable {
    public var mesh: AssetID
    public var materials: [AssetID]
    public var castsShadows = true
    public var receivesShadows = true
    /// Static objects are eligible for ray-tracing BLAS reuse and batched submission.
    public var isStatic = false
    public init(mesh: AssetID, materials: [AssetID] = []) {
        self.mesh = mesh
        self.materials = materials
    }
}

/// Per-instance material property overrides (material instancing without new assets).
public struct MaterialOverrides: Component, Codable, Hashable, Sendable {
    public var baseColor: Color?
    public var emissive: Color?
    public var metallic: Float?
    public var roughness: Float?
    public init() {}
}

/// Skinned mesh binding: references the skeleton's joint entities.
public struct SkinnedMeshRenderer: Component, Codable, Hashable, Sendable {
    public var mesh: AssetID
    public var materials: [AssetID]
    public var skin: AssetID
    /// Joint entities in skin order (resolved at instantiation).
    public var joints: [Entity] = []
    public var castsShadows = true
    public var receivesShadows = true
    public init(mesh: AssetID, materials: [AssetID], skin: AssetID) {
        self.mesh = mesh
        self.materials = materials
        self.skin = skin
    }

    private enum CodingKeys: String, CodingKey { case mesh, materials, skin, joints, castsShadows, receivesShadows }

    /// The shadow flags were added later; files without them load with both set to true.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mesh = try c.decode(AssetID.self, forKey: .mesh)
        materials = try c.decode([AssetID].self, forKey: .materials)
        skin = try c.decode(AssetID.self, forKey: .skin)
        joints = try c.decodeIfPresent([Entity].self, forKey: .joints) ?? []
        castsShadows = try c.decodeIfPresent(Bool.self, forKey: .castsShadows) ?? true
        receivesShadows = try c.decodeIfPresent(Bool.self, forKey: .receivesShadows) ?? true
    }
}

/// Level-of-detail selection by projected screen height.
public struct LODGroup: Component, Codable, Hashable, Sendable {
    public struct Level: Codable, Hashable, Sendable {
        public var mesh: AssetID
        /// Use this level while the object covers at least this fraction of screen height.
        public var screenHeight: Float
        public init(mesh: AssetID, screenHeight: Float) {
            self.mesh = mesh
            self.screenHeight = screenHeight
        }
    }
    public var levels: [Level]
    /// Beyond the last level's threshold the object is culled.
    public var cullBelowLastLevel = true
    public init(levels: [Level]) { self.levels = levels.sorted { $0.screenHeight > $1.screenHeight } }

    /// Chooses a level for a projected screen-height fraction; nil means culled.
    public func select(screenHeight h: Float, bias: Float = 1) -> Int? {
        let hb = h * bias
        for (i, l) in levels.enumerated() where hb >= l.screenHeight { return i }
        return cullBelowLastLevel ? nil : (levels.isEmpty ? nil : levels.count - 1)
    }
}

public enum SpriteBlendMode: String, Codable, Sendable, CaseIterable { case alpha, additive, multiply, premultiplied, opaque }
public enum TextureFilter: String, Codable, Sendable, CaseIterable { case nearest, linear }

/// A textured quad rendered by the 2D batcher.
public struct SpriteRenderer: Component, Codable, Hashable, Sendable {
    public var texture: AssetID
    /// Sub-rectangle in normalised texture coordinates (atlas frame).
    public var uvRect: Rect = .unit
    /// Size in world units; nil derives it from the frame size and `pixelsPerUnit`.
    public var size: Vec2?
    public var pixelsPerUnit: Float = 100
    public var pivot: Vec2 = Vec2(0.5, 0.5)
    public var color: Color = .white
    public var flipX = false
    public var flipY = false
    /// Sorting layer (major) and order within it (minor). Higher draws on top.
    public var sortingLayer: Int = 0
    public var orderInLayer: Int = 0
    public var blend: SpriteBlendMode = .alpha
    public var filter: TextureFilter = .linear
    /// Optional normal map for 2D lighting.
    public var normalMap: AssetID?
    /// Writes this sprite into the stencil mask with `maskID` (1–255) instead of colour.
    public var isMask = false
    /// Only draws where the stencil equals `maskID` (0 = unmasked).
    public var maskID: UInt8 = 0
    public var receives2DLighting = false

    public init(texture: AssetID, size: Vec2? = nil) {
        self.texture = texture
        self.size = size
    }
}

/// Untextured 2D shape rendered by the batcher (tessellated on the CPU).
public struct ShapeRenderer: Component, Codable, Hashable, Sendable {
    public enum Shape: Codable, Hashable, Sendable {
        case rectangle(size: Vec2, cornerRadius: Float)
        case circle(radius: Float, segments: Int)
        case polygon(points: [Vec2])
        case line(from: Vec2, to: Vec2)
        case polyline(points: [Vec2], closed: Bool)
    }
    public var shape: Shape
    public var fill: Gradient
    public var strokeWidth: Float = 0
    public var strokeColor: Color = .black
    public var sortingLayer = 0
    public var orderInLayer = 0
    public init(_ shape: Shape, color: Color = .white) {
        self.shape = shape
        fill = Gradient(color, color)
    }
}

/// Parallax factor for 2D layers: 0 = fixed to camera, 1 = world-locked.
public struct Parallax: Component, Codable, Hashable, Sendable {
    public var factor: Vec2
    public init(_ factor: Vec2) { self.factor = factor }
}

/// Grid of tiles drawn from a tileset atlas.
public struct Tilemap: Component, Codable, Hashable, Sendable {
    public var tileset: AssetID
    /// Tileset grid size in tiles.
    public var tilesetColumns: Int
    public var tilesetRows: Int
    public var width: Int
    public var height: Int
    public var tileSize: Vec2 = Vec2(1, 1)
    /// Tile indices (row-major, bottom row first); -1 = empty.
    public var tiles: [Int32]
    public var sortingLayer = 0
    public var color: Color = .white
    /// Incremented on edit so the renderer can rebuild only changed chunks.
    public var revision: UInt64 = 0
    /// Tiles with these indices generate static colliders (see `TilemapCollider`).
    public var solidTiles: Set<Int32> = []

    public init(tileset: AssetID, columns: Int, rows: Int, width: Int, height: Int) {
        self.tileset = tileset
        tilesetColumns = max(1, columns)
        tilesetRows = max(1, rows)
        self.width = max(0, width)
        self.height = max(0, height)
        tiles = Array(repeating: -1, count: self.width * self.height)
    }

    public subscript(x: Int, y: Int) -> Int32 {
        get { (x >= 0 && y >= 0 && x < width && y < height) ? tiles[y * width + x] : -1 }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            tiles[y * width + x] = newValue
            revision &+= 1
        }
    }

    /// UV rect of a tile index in the tileset.
    public func uvRect(for tile: Int32) -> Rect {
        let col = Int(tile) % tilesetColumns
        let row = Int(tile) / tilesetColumns
        let w = 1 / Float(tilesetColumns), h = 1 / Float(tilesetRows)
        return Rect(x: Float(col) * w, y: Float(row) * h, width: w, height: h)
    }
}

/// Scene environment: sky, image-based lighting and ambient settings. One per scene.
public struct Environment: Component, Codable, Hashable, Sendable {
    public enum Sky: Codable, Hashable, Sendable {
        /// Analytic sky (Preetham-style gradient + sun disc), generated on the GPU.
        case procedural(sunDirection: Vec3, turbidity: Float)
        /// Equirectangular HDR or cubemap asset.
        case texture(AssetID)
        case color(Color)
    }
    public var sky: Sky = .procedural(sunDirection: Vec3(0.3, 0.8, 0.4).normalized, turbidity: 2.5)
    public var iblIntensity: Float = 1
    public var skyIntensity: Float = 1
    public var ambientColor: Color = Color(0.03, 0.03, 0.035)
    public var fogDensity: Float = 0
    public var fogColor: Color = Color(0.5, 0.6, 0.7)
    public init() {}
}

/// Captures surrounding radiance into a prefiltered cubemap for local reflections.
public struct ReflectionProbe: Component, Codable, Hashable, Sendable {
    public var resolution = 128
    /// Influence volume half-extents (box projection).
    public var extents = Vec3(10, 10, 10)
    public var boxProjection = true
    /// Re-render every frame (expensive) instead of once on demand.
    public var realtime = false
    public var revision: UInt64 = 0
    public init() {}
}
