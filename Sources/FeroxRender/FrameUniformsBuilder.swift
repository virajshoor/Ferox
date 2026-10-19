import FeroxCore
import FeroxScene
import Foundation

/// Builds the camera- and environment-dependent part of `FrameUniforms`.
///
/// Lighting fields (sun, cascades, light counts, flags) are filled later by the scene
/// passes; post-processing state (`exposure.x` when auto exposure runs on the GPU,
/// `effectFlags`) is set by the renderer. Keeping this in plain Swift lets the matrix
/// bookkeeping — jitter, previous-frame matrices, reciprocals — be unit-tested on Linux.
public enum FrameUniformsBuilder {
    /// Inputs that come from the previous frame of the same view.
    public struct History: Sendable {
        public var viewProjection: Mat4
        public var unjitteredViewProjection: Mat4
        public var jitter: Vec2
        public init(viewProjection: Mat4, unjitteredViewProjection: Mat4, jitter: Vec2) {
            self.viewProjection = viewProjection
            self.unjitteredViewProjection = unjitteredViewProjection
            self.jitter = jitter
        }
    }

    /// - Parameters:
    ///   - camera: The view being rendered.
    ///   - width, height: Render resolution in pixels (after dynamic resolution scaling).
    ///   - jitter: Sub-pixel offset in NDC units (zero without temporal AA / upscaling).
    ///   - previous: Last frame's matrices; nil on the first frame or after a camera cut,
    ///     in which case the current matrices are used so motion vectors are zero.
    ///   - environment: Ambient, fog and sky intensity.
    ///   - exposure: Linear exposure multiplier (manual, or last frame's adapted value).
    ///   - time: Elapsed time in seconds (`cameraPosition.w`, shader animation).
    ///   - frameIndex: Monotonic frame counter (noise seeds, `exposure.y`).
    ///   - environmentMips: Mip count of the prefiltered environment (`exposure.z`).
    public static func make(
        camera: RenderCamera, width: Int, height: Int, jitter: Vec2, previous: History?,
        environment: Environment, exposure: Float, time: Double, frameIndex: UInt64,
        environmentMips: Int
    ) -> FrameUniforms {
        var u = FrameUniforms()
        let w = Float(max(width, 1))
        let h = Float(max(height, 1))
        let projection =
            jitter == .zero
            ? camera.projection
            : camera.camera.projectionMatrix(aspect: camera.aspect, jitter: jitter)
        u.view = camera.view
        u.projection = projection
        u.viewProjection = projection * camera.view
        u.inverseViewProjection = u.viewProjection.inverse
        u.inverseProjection = projection.inverse
        u.inverseView = camera.world
        u.unjitteredViewProjection = camera.viewProjection
        u.previousViewProjection = previous?.viewProjection ?? u.viewProjection
        u.previousUnjitteredViewProjection = previous?.unjitteredViewProjection ?? camera.viewProjection
        // `Float(time)` loses precision after ~days of uptime; wrap at one hour so shader
        // animation stays smooth (period-sensitive effects should use their own clocks).
        u.cameraPosition = Vec4(camera.position, Float(time.truncatingRemainder(dividingBy: 3600)))
        u.viewport = Vec4(w, h, 1 / w, 1 / h)
        let prevJitter = previous?.jitter ?? jitter
        u.jitter = Vec4(jitter.x, jitter.y, prevJitter.x, prevJitter.y)
        u.ambient = Vec4(environment.ambientColor.rgb, max(environment.iblIntensity, 0))
        u.fog = Vec4(environment.fogColor.rgb, max(environment.fogDensity, 0))
        // Frame index modulo 2^24 stays exactly representable as a Float.
        u.exposure = Vec4(
            max(exposure, 0), Float(frameIndex % (1 << 24)), Float(max(environmentMips, 1)),
            max(environment.skyIntensity, 0))
        return u
    }

    /// The six cube-face cameras of a reflection probe at `position`, in Metal's face order
    /// (+X, −X, +Y, −Y, +Z, −Z) and orientation (matching `cubeDirection` in Sky.metal:
    /// texel (0, 0) is the top-left of each face as seen from inside the cube).
    ///
    /// Cube faces are addressed in a left-handed frame, so every camera basis is mirrored
    /// (determinant −1). Triangles therefore appear with reversed winding; the capture pass
    /// must treat clockwise triangles as front-facing (`ScenePasses.frontFacing`).
    public static func cubeFaceCameras(position: Vec3, near: Float, far: Float) -> [RenderCamera] {
        // (forward, screen right, screen up) per face.
        let faces: [(Vec3, Vec3, Vec3)] = [
            (Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)),
            (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1)),
            (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)),
            (Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)),
        ]
        var cam = Camera()
        cam.projection = .perspective
        cam.fieldOfView = .pi / 2
        cam.near = max(near, 1e-3)
        cam.far = max(far, cam.near + 1)
        return faces.map { forward, right, up in
            // Cameras look down their local −Z, so the third column is −forward.
            let m = Mat4(columns: Vec4(right, 0), Vec4(up, 0), Vec4(-forward, 0), Vec4(position, 1))
            return RenderCamera(entity: .null, camera: cam, worldMatrix: m, aspect: 1)
        }
    }
}
