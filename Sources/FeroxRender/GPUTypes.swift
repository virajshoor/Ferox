import FeroxCore
import Foundation

// GPU-facing structures shared with `Shaders/Common.metal`. Every struct here uses only
// 16-byte vectors/matrices (or groups of four scalars) so that Swift and MSL layouts are
// identical without packing pragmas. `GPUTypesTests` asserts the sizes below.
//
// When changing any of these, update Common.metal in the same commit.

/// Per-view constants (buffer index `BufferIndex.frame`).
public struct FrameUniforms {
    public var view = Mat4.identity
    public var projection = Mat4.identity
    public var viewProjection = Mat4.identity
    public var inverseViewProjection = Mat4.identity
    public var previousViewProjection = Mat4.identity
    public var inverseProjection = Mat4.identity
    public var inverseView = Mat4.identity
    /// Unjittered view-projection (motion vectors are computed between unjittered positions).
    public var unjitteredViewProjection = Mat4.identity
    public var previousUnjitteredViewProjection = Mat4.identity
    /// xyz camera position, w elapsed time.
    public var cameraPosition = Vec4.zero
    /// x,y render size in pixels; z,w reciprocal.
    public var viewport = Vec4.zero
    /// xy current jitter (NDC), zw previous jitter.
    public var jitter = Vec4.zero
    /// xyz direction towards the sun, w intensity (lux, pre-exposed).
    public var sunDirection = Vec4.zero
    /// rgb sun colour, a = 1 when the sun casts shadows.
    public var sunColor = Vec4.zero
    /// rgb ambient, a IBL intensity.
    public var ambient = Vec4.zero
    /// rgb fog colour, a density.
    public var fog = Vec4.zero
    /// x near, y far, z slice scale, w slice bias (clustered depth slicing).
    public var clusterParams = Vec4.zero
    /// x,y,z cluster grid dimensions, w max lights per cluster.
    public var clusterDims = SIMD4<UInt32>(16, 9, 24, 64)
    /// x punctual light count, y directional light count, z reflection probe count, w flags.
    public var lightCounts = SIMD4<UInt32>.zero
    /// x exposure, y frame index, z environment mip count, w sky intensity.
    public var exposure = Vec4(1, 0, 1, 1)
    public var shadowMatrices = (Mat4.identity, Mat4.identity, Mat4.identity, Mat4.identity)
    /// View-space split distances of the cascades.
    public var cascadeSplits = Vec4.zero
    /// x depth bias, y normal bias, z texel size, w cascade count.
    public var shadowParams = Vec4.zero
    /// x = 1 when ray-traced shadows replace shadow maps, y = RT AO active, z = RT reflections
    /// active, w = SSAO active.
    public var effectFlags = Vec4.zero
    public init() {}
}

public enum FrameFlags {
    public static let clustered: UInt32 = 1
    public static let shadows: UInt32 = 2
    public static let pcss: UInt32 = 4
    public static let reverseZ: UInt32 = 8
}

/// Per-instance transform and overrides.
public struct InstanceData {
    public var model = Mat4.identity
    public var previousModel = Mat4.identity
    /// Normal matrix columns (xyz) — inverse transpose of the model's upper 3×3.
    public var normal0 = Vec4.zero
    public var normal1 = Vec4.zero
    public var normal2 = Vec4.zero
    /// Multiplied with the material base colour.
    public var colorTint = Vec4(1, 1, 1, 1)
    /// Added to the material emissive (rgb), a unused.
    public var emissiveAdd = Vec4.zero
    /// x metallic override (<0 = none), y roughness override (<0 = none), z bounding radius,
    /// w joint palette offset (skinned meshes).
    public var params = Vec4(-1, -1, 1, 0)
    /// World-space bounding sphere (xyz centre, w radius) for GPU culling.
    public var bounds = Vec4.zero
    public init() {}

    public init(model: Mat4, previous: Mat4) {
        self.init()
        self.model = model
        previousModel = previous
        let n = model.normalMatrix
        normal0 = Vec4(n.c0, 0)
        normal1 = Vec4(n.c1, 0)
        normal2 = Vec4(n.c2, 0)
    }
}

/// Packed punctual light.
public struct LightData {
    /// xyz position (world), w range.
    public var positionRange = Vec4.zero
    /// rgb colour × intensity, w type (0 directional, 1 point, 2 spot).
    public var color = Vec4.zero
    /// xyz direction the light points to, w cos(outer angle).
    public var direction = Vec4.zero
    /// x cos(inner angle), yzw unused.
    public var extra = Vec4.zero
    public init() {}
}

/// Material constants.
public struct MaterialUniforms {
    public var baseColor = Vec4(1, 1, 1, 1)
    /// rgb emissive × strength.
    public var emissive = Vec4.zero
    /// x metallic, y roughness, z normal scale, w occlusion strength.
    public var params = Vec4(0, 0.5, 1, 1)
    /// x alpha cutoff, y alpha mode (0 opaque, 1 mask, 2 blend), z unlit, w double sided.
    public var params2 = Vec4(0.5, 0, 0, 0)
    /// x texture presence bits (see `MaterialTextureBits`), yzw custom.
    public var flags = SIMD4<UInt32>.zero
    public var custom = Vec4.zero
    public init() {}
}

public enum MaterialTextureBits {
    public static let baseColor: UInt32 = 1
    public static let normal: UInt32 = 2
    public static let metallicRoughness: UInt32 = 4
    public static let occlusion: UInt32 = 8
    public static let emissive: UInt32 = 16
}

/// Reflection probe data (box projection).
public struct ProbeData {
    /// xyz centre, w blend distance.
    public var center = Vec4.zero
    /// xyz half extents, w array slice.
    public var extents = Vec4.zero
    public init() {}
}

/// 2D batch vertex (48-byte stride: SIMD4 alignment pads the trailing SIMD2).
public struct SpriteVertex {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>
    /// Premultiplied linear colour.
    public var color: SIMD4<Float>
    /// x = receives 2D lighting, y = layer depth (unused by default).
    public var extra: SIMD2<Float>
    public init(position: SIMD2<Float>, uv: SIMD2<Float>, color: SIMD4<Float>, lit: Bool = false) {
        self.position = position
        self.uv = uv
        self.color = color
        extra = SIMD2(lit ? 1 : 0, 0)
    }
}

/// UI vertex (80 bytes): position, uv, colour, rect info for SDF rounded corners.
public struct UIVertex {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>
    public var color: SIMD4<Float>
    /// Rect centre (xy) and half size (zw) in points, for rounded-rect SDF.
    public var rect: SIMD4<Float>
    /// x corner radius, y border width, z mode (0 solid, 1 texture, 2 glyph), w unused.
    public var params: SIMD4<Float>
    public var borderColor: SIMD4<Float>
    public init(position: SIMD2<Float>, uv: SIMD2<Float>, color: SIMD4<Float>, rect: SIMD4<Float>,
                params: SIMD4<Float>, borderColor: SIMD4<Float>) {
        self.position = position
        self.uv = uv
        self.color = color
        self.rect = rect
        self.params = params
        self.borderColor = borderColor
    }
}

/// Debug line vertex (32 bytes).
public struct LineVertex {
    public var position: SIMD4<Float>
    public var color: SIMD4<Float>
    public init(_ p: Vec3, _ c: Color) {
        position = Vec4(p, 1)
        color = c.premultiplied
    }
}

/// Mesh vertex layout used for all static meshes (72 bytes, interleaved).
/// Offsets: position 0 (packed float3), normal 12 (packed float3), tangent 24 (float4),
/// uv0 40, uv1 48, colour 56.
public enum MeshVertexLayout {
    public static let stride = 72
    public static let positionOffset = 0
    public static let normalOffset = 12
    public static let tangentOffset = 24
    public static let uv0Offset = 40
    public static let uv1Offset = 48
    public static let colorOffset = 56
    /// Skinning stream (separate buffer): joints ushort4 at 0, weights float4 at 8.
    public static let skinStride = 24
}

/// Buffer argument indices shared with the shaders.
public enum BufferIndex {
    public static let vertices = 0
    public static let skin = 1
    public static let frame = 2
    public static let instances = 3
    public static let material = 4
    public static let lights = 5
    public static let clusterCounts = 6
    public static let clusterIndices = 7
    public static let joints = 8
    public static let instanceIndices = 9
    public static let probes = 10
    public static let cascade = 11
}

/// Texture argument indices shared with the shaders.
public enum TextureIndex {
    public static let baseColor = 0
    public static let normal = 1
    public static let metallicRoughness = 2
    public static let occlusion = 3
    public static let emissive = 4
    public static let prefiltered = 5
    public static let brdfLUT = 6
    public static let shadowMap = 7
    public static let rtShadow = 8
    public static let reflection = 9
    public static let ambientOcclusion = 10
    public static let irradiance = 11
    public static let probes = 12
}

// MARK: - Pass-specific constants (mirrors of the structs declared in each shader module)

/// Post-processing constants (`Post.metal`, buffer 0). 14 × 16 bytes.
public struct PostUniforms {
    /// x threshold, y soft knee, z intensity, w upsample radius.
    public var bloom = Vec4.zero
    /// x operator (0 none, 1 Reinhard, 2 ACES, 3 AgX), y exposure multiplier, z contrast, w saturation.
    public var tonemap = Vec4(3, 1, 1, 1)
    /// xyz LMS white-balance scale, w vignette.
    public var whiteBalance = Vec4(1, 1, 1, 0)
    /// rgb lift, a auto exposure enabled.
    public var lift = Vec4.zero
    /// rgb gamma, a dither strength.
    public var gamma = Vec4(1, 1, 1, 1)
    /// rgb gain.
    public var gain = Vec4(1, 1, 1, 0)
    /// x focus distance (m), y f-number, z focal length (m), w max circle of confusion (px).
    public var dof = Vec4.zero
    /// x shutter fraction, y sample count, z max length (px).
    public var motionBlur = Vec4.zero
    /// x history feedback, z sharpness, w reset.
    public var taa = Vec4.zero
    /// x amount.
    public var sharpen = Vec4.zero
    /// x radius, y intensity, z bias, w sample count.
    public var ssao = Vec4.zero
    /// xy source size, zw destination size (pixels).
    public var sizes = Vec4.zero
    /// xy 1/source size, zw 1/destination size.
    public var texel = Vec4.zero
    /// x frame index, y delta time, z exposure adaptation speed, w mip / pass index.
    public var misc = Vec4.zero
    public init() {}

    /// Sets `sizes` and `texel` for a pass reading `source` and writing `destination`.
    public mutating func setSizes(source: SIMD2<Int>, destination: SIMD2<Int>) {
        let s = Vec2(Float(max(source.x, 1)), Float(max(source.y, 1)))
        let d = Vec2(Float(max(destination.x, 1)), Float(max(destination.y, 1)))
        sizes = Vec4(s.x, s.y, d.x, d.y)
        texel = Vec4(1 / s.x, 1 / s.y, 1 / d.x, 1 / d.y)
    }
}

/// Sky and image-based-lighting generation constants (`Sky.metal`, buffer 0).
public struct SkyParams {
    /// xyz towards the sun, w turbidity.
    public var sunDirection = Vec4(0, 1, 0, 2.5)
    /// rgb ground colour, a sun disc angular radius (radians).
    public var groundColor = Vec4(0.1, 0.1, 0.1, 0.0047)
    /// rgb flat colour (mode 2), a overall scale.
    public var tint = Vec4(1, 1, 1, 1)
    /// x mode (0 procedural, 1 equirect, 2 colour), y face size, z sample count, w mip.
    public var mode = SIMD4<UInt32>.zero
    /// x roughness (prefilter), y source resolution.
    public var filter = Vec4.zero
    public init() {}
}

/// Ray-tracing constants (`RayTracing.metal`, buffer 0).
public struct RTUniforms {
    /// x AO radius, y max reflection roughness, z sun cone half-angle, w frame index.
    public var params = Vec4.zero
    /// xy output size, z rays per pixel, w flags (bit 0 history valid).
    public var size = SIMD4<UInt32>.zero
    /// x à-trous step, y depth sigma, z normal power, w temporal blend.
    public var denoise = Vec4(1, 0.05, 32, 0.15)
    /// xy full-resolution depth size, zw 1/output size.
    public var depthSize = Vec4.zero
    public init() {}
}

/// Constant material values for reflection-ray hits, indexed by acceleration-structure instance.
public struct RTInstanceMaterial {
    public var albedoRoughness = Vec4(1, 1, 1, 0.5)
    public var emissiveMetallic = Vec4.zero
    public init() {}
}

/// GPU culling constants (`Culling.metal`, buffer 0).
public struct CullUniforms {
    public var planes = (Vec4.zero, Vec4.zero, Vec4.zero, Vec4.zero, Vec4.zero, Vec4.zero)
    public var previousViewProjection = Mat4.identity
    /// xy mip-0 size, z mip count.
    public var hizSize = Vec4.zero
    /// x instance count, y flags (bit 0 occlusion), z batch count.
    public var counts = SIMD4<UInt32>.zero
    public init() {}
}

/// 2D batch constants (`Sprite.metal`, buffer 1).
public struct Sprite2DUniforms {
    public var viewProjection = Mat4.identity
    /// rgb ambient light for lit sprites.
    public var ambient = Vec4(1, 1, 1, 1)
    /// x light count, y flags (bit 0 normal map).
    public var counts = SIMD4<UInt32>.zero
    /// x pixel snap, yz target size, w mask alpha cut-off.
    public var params = Vec4(0, 1, 1, 0.5)
    public init() {}
}

/// A 2D light (`Sprite.metal`, buffer 2).
public struct Light2D {
    /// xy position, z height, w radius.
    public var positionRadius = Vec4.zero
    /// rgb colour × intensity, a falloff exponent.
    public var color = Vec4(1, 1, 1, 1)
    /// x inner radius fraction, y spot cosine (≤ -1 point light), zw spot direction.
    public var params = Vec4(0, -2, 0, 0)
    public init() {}
}

/// UI constants (`UI.metal`, buffer 1).
public struct UIUniforms {
    /// xy viewport size in points, zw content scale.
    public var viewport = Vec4(1, 1, 1, 1)
    public init() {}
}

/// GPU particle (`Particles.metal`). 64 bytes.
public struct GPUParticle {
    /// xyz position, w lifetime.
    public var posLife = Vec4.zero
    /// xyz velocity, w age.
    public var velAge = Vec4.zero
    /// Premultiplied linear colour.
    public var color = Vec4(1, 1, 1, 1)
    /// x start size, y end size, z rotation, w angular velocity.
    public var sizeRot = Vec4(0.1, 0.1, 0, 0)
    public init() {}
}

/// GPU particle simulation constants (`Particles.metal`, buffer 0).
public struct ParticleSimUniforms {
    /// xyz gravity, w drag.
    public var gravityDrag = Vec4.zero
    /// x dt, y fade-out fraction.
    public var params = Vec4.zero
    /// x capacity, y spawn count, z ring offset.
    public var counts = SIMD4<UInt32>.zero
    public init() {}
}
