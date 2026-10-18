import FeroxCore
import Foundation

// Point- and spot-light shadow planning. Like `RenderScene`, this file holds no Metal code,
// so slice assignment and the light matrices are unit-tested on Linux.
//
// Every shadowed local light renders into slices of one depth 2D array (`ScenePasses`):
// a spot light takes one slice, a point light six, one per cube face. The forward shader
// finds a light's slices through `LightData.extra.y` and projects the surface with the
// matching matrix from `BufferIndex.localShadowMatrices`.

/// One point- or spot-light shadow slice.
public struct LocalShadowSlice: Sendable, Hashable {
    /// Index of the light in `RenderFrameData.lights`.
    public var light: Int
    /// 0 for a spot light; the cube face (+X, −X, +Y, −Y, +Z, −Z) for a point light.
    public var face: Int
    /// World → light clip space, standard Z (near 0, far 1), as the shadow pass renders it.
    public var viewProjection: Mat4
    /// World-space light position and range, for culling casters against the light.
    public var position: Vec3
    public var range: Float
}

public enum LocalShadowPlanner {
    /// Upper bound on slices, whatever `ShadowSettings.localShadowSlices` asks for.
    public static let maxSlices = 64

    /// Cube-face view directions and up vectors, in the order the shader selects faces
    /// (dominant axis of the light-to-surface vector, positive before negative).
    public static let pointFaces: [(direction: Vec3, up: Vec3)] = [
        (Vec3(1, 0, 0), Vec3(0, -1, 0)), (Vec3(-1, 0, 0), Vec3(0, -1, 0)),
        (Vec3(0, 1, 0), Vec3(0, 0, 1)), (Vec3(0, -1, 0), Vec3(0, 0, -1)),
        (Vec3(0, 0, 1), Vec3(0, -1, 0)), (Vec3(0, 0, -1), Vec3(0, -1, 0)),
    ]

    /// The cube face the shader samples for a surface at `offset` from a point light.
    public static func pointFace(for offset: Vec3) -> Int {
        let a = Vec3(abs(offset.x), abs(offset.y), abs(offset.z))
        if a.x >= a.y && a.x >= a.z { return offset.x >= 0 ? 0 : 1 }
        if a.y >= a.z { return offset.y >= 0 ? 2 : 3 }
        return offset.z >= 0 ? 4 : 5
    }

    /// Near plane of a local shadow projection: small against the range, never zero.
    static func nearPlane(range: Float) -> Float { min(max(range * 0.01, 0.02), range * 0.5) }

    /// A face field of view slightly wider than 90°, so the 3 × 3 filter kernel near a face
    /// edge still reads inside the face it was projected into.
    static func pointFieldOfView(resolution: Int) -> Float {
        2 * atan(1 + 4 / Float(max(resolution, 1)))
    }

    /// The view-projection of one point-light cube face.
    public static func pointFaceMatrix(position: Vec3, range: Float, face: Int, resolution: Int) -> Mat4 {
        let f = pointFaces[min(max(face, 0), 5)]
        let projection = Mat4.perspective(fovY: pointFieldOfView(resolution: resolution), aspect: 1,
                                          near: nearPlane(range: range), far: max(range, 0.05), reverseZ: false)
        return projection * Mat4.lookAt(eye: position, target: position + f.direction, up: f.up)
    }

    /// The view-projection of a spot light whose cone has half-angle `acos(cosOuter)`.
    public static func spotMatrix(position: Vec3, direction: Vec3, cosOuter: Float, range: Float,
                                  resolution: Int) -> Mat4 {
        let halfAngle = acos(min(max(cosOuter, 0.0), 1))
        // A small margin keeps the kernel inside the map at the cone's rim.
        let fov = min(2 * halfAngle + 8 / Float(max(resolution, 1)), .pi * 0.95)
        let dir = direction.lengthSquared > 1e-8 ? direction.normalized : Vec3.forward
        let up = abs(dir.y) > 0.99 ? Vec3(0, 0, 1) : Vec3.up
        let projection = Mat4.perspective(fovY: fov, aspect: 1, near: nearPlane(range: range),
                                          far: max(range, 0.05), reverseZ: false)
        return projection * Mat4.lookAt(eye: position, target: position + dir, up: up)
    }

    /// World-space size of one shadow texel at unit distance, for the normal-offset bias.
    static func texelAngle(fov: Float, resolution: Int) -> Float {
        2 * tan(fov * 0.5) / Float(max(resolution, 1))
    }

    /// Gives shadow slices to `candidates` (indices into `lights`, nearest first) until the
    /// budget runs out, writes each served light's first slice, texel size and bias into
    /// `LightData.extra`, and returns the slices in slice order. A point light that does not
    /// fit in the remaining slices is skipped, and a smaller spot light may still fit.
    public static func plan(lights: inout [LightData], candidates: [Int], budget: Int, resolution: Int,
                            normalBias: Float) -> [LocalShadowSlice] {
        let limit = min(max(budget, 0), maxSlices)
        let res = min(max(resolution, 64), 4096)
        var slices: [LocalShadowSlice] = []
        for index in candidates where lights.indices.contains(index) {
            var l = lights[index]
            let isPoint = l.color.w < 1.5
            guard l.color.w > 0.5 else { continue }  // directional lights have no local shadow
            let needed = isPoint ? 6 : 1
            guard slices.count + needed <= limit else { continue }
            let position = l.positionRange.xyz
            let range = l.positionRange.w
            let fov: Float
            l.extra.y = Float(slices.count)
            if isPoint {
                fov = pointFieldOfView(resolution: res)
                for face in 0..<6 {
                    slices.append(LocalShadowSlice(
                        light: index, face: face,
                        viewProjection: pointFaceMatrix(position: position, range: range, face: face, resolution: res),
                        position: position, range: range))
                }
            } else {
                fov = 2 * acos(min(max(l.direction.w, 0), 1))
                slices.append(LocalShadowSlice(
                    light: index, face: 0,
                    viewProjection: spotMatrix(position: position, direction: l.direction.xyz, cosOuter: l.direction.w,
                                               range: range, resolution: res),
                    position: position, range: range))
            }
            l.extra.z = 1 / Float(res)
            // Offset along the normal by about 1.5 texels at the surface's distance (the
            // shader multiplies by that distance), plus the user's normal bias.
            l.extra.w = texelAngle(fov: fov, resolution: res) * 1.5 + max(normalBias, 0) * 0.05
            lights[index] = l
        }
        return slices
    }
}
