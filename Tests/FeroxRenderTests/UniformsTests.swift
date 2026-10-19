import Ferox
/// Tests for the CPU-side uniform builders (`FrameUniformsBuilder`, `PostUniformsBuilder`)
/// and the dynamic resolution controller. None of these touch Metal.
import XCTest

@testable import FeroxRender

final class FrameUniformsTests: XCTestCase {
    func makeCamera() -> RenderCamera {
        let world = Mat4(
            translation: Vec3(1, 2, 3), rotation: Quat(pitch: -0.2, yaw: 0.5, roll: 0), scale: Vec3(1, 1, 1))
        return RenderCamera(
            entity: .null, camera: .perspective(fov: 70, near: 0.1, far: 300), worldMatrix: world, aspect: 16.0 / 9)
    }

    func make(
        _ camera: RenderCamera, jitter: Vec2 = .zero, previous: FrameUniformsBuilder.History? = nil,
        time: Double = 1, frame: UInt64 = 7
    ) -> FrameUniforms {
        FrameUniformsBuilder.make(
            camera: camera, width: 1280, height: 720, jitter: jitter, previous: previous,
            environment: Environment(), exposure: 0.5, time: time, frameIndex: frame,
            environmentMips: 8)
    }

    // Without jitter or history, the jittered and unjittered matrices coincide and the
    // previous frame equals the current one (zero motion vectors on the first frame).
    func testFirstFrameHasNoMotion() {
        let cam = makeCamera()
        let u = make(cam)
        XCTAssertTrue(u.projection.isApproximatelyEqual(to: cam.projection))
        XCTAssertTrue(u.viewProjection.isApproximatelyEqual(to: cam.viewProjection))
        XCTAssertTrue(u.previousViewProjection.isApproximatelyEqual(to: u.viewProjection))
        XCTAssertTrue(u.previousUnjitteredViewProjection.isApproximatelyEqual(to: cam.viewProjection))
        XCTAssertEqual(u.jitter, Vec4(0, 0, 0, 0))
    }

    // Inverses really are inverses, and the viewport stores size and reciprocal size.
    func testInversesAndViewport() {
        let u = make(makeCamera())
        XCTAssertTrue((u.viewProjection * u.inverseViewProjection).isApproximatelyEqual(to: .identity, tolerance: 1e-3))
        XCTAssertTrue((u.projection * u.inverseProjection).isApproximatelyEqual(to: .identity, tolerance: 1e-3))
        XCTAssertTrue((u.view * u.inverseView).isApproximatelyEqual(to: .identity, tolerance: 1e-4))
        XCTAssertEqual(u.viewport, Vec4(1280, 720, 1 / 1280, 1 / 720))
        XCTAssertEqual(u.cameraPosition.x, 1, accuracy: 1e-5)
        XCTAssertEqual(u.cameraPosition.y, 2, accuracy: 1e-5)
        XCTAssertEqual(u.cameraPosition.z, 3, accuracy: 1e-5)
    }

    // Jitter changes the projection but not the unjittered matrix; the previous frame's
    // jitter is carried in jitter.zw.
    func testJitterAndHistory() {
        let cam = makeCamera()
        let j = Vec2(0.0005, -0.0007)
        let history = FrameUniformsBuilder.History(
            viewProjection: .identity, unjitteredViewProjection: .identity,
            jitter: Vec2(0.0001, 0.0002))
        let u = make(cam, jitter: j, previous: history)
        XCTAssertFalse(u.projection.isApproximatelyEqual(to: cam.projection, tolerance: 1e-6))
        XCTAssertTrue(u.unjitteredViewProjection.isApproximatelyEqual(to: cam.viewProjection))
        XCTAssertEqual(u.previousViewProjection, .identity)
        XCTAssertEqual(u.previousUnjitteredViewProjection, .identity)
        XCTAssertEqual(u.jitter, Vec4(j.x, j.y, 0.0001, 0.0002))
    }

    // Time wraps hourly and the frame index wraps at 2^24, so both stay exact as Float.
    func testTimeAndFrameIndexWrap() {
        let cam = makeCamera()
        XCTAssertEqual(make(cam, time: 3600 + 12.5).cameraPosition.w, 12.5, accuracy: 1e-4)
        XCTAssertEqual(make(cam, frame: (1 << 24) + 3).exposure.y, 3)
        let u = make(cam)
        XCTAssertEqual(u.exposure.x, 0.5)
        XCTAssertEqual(u.exposure.z, 8)
    }

    // Degenerate sizes and negative environment values are clamped.
    func testClamping() {
        var env = Environment()
        env.fogDensity = -1
        env.iblIntensity = -2
        env.skyIntensity = -3
        let u = FrameUniformsBuilder.make(
            camera: makeCamera(), width: 0, height: 0, jitter: .zero, previous: nil,
            environment: env, exposure: -1, time: 0, frameIndex: 0, environmentMips: 0)
        XCTAssertEqual(u.viewport, Vec4(1, 1, 1, 1))
        XCTAssertEqual(u.fog.w, 0)
        XCTAssertEqual(u.ambient.w, 0)
        XCTAssertEqual(u.exposure, Vec4(0, 0, 1, 0))
    }

    // Six probe cameras in Metal face order, 90° square, each with a mirrored basis.
    func testCubeFaceCameras() {
        let p = Vec3(4, 5, 6)
        let cams = FrameUniformsBuilder.cubeFaceCameras(position: p, near: 0.05, far: 80)
        XCTAssertEqual(cams.count, 6)
        let forwards = [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)]
        for (cam, f) in zip(cams, forwards) {
            XCTAssertTrue(cam.forward.isApproximatelyEqual(to: f, tolerance: 1e-5), "forward \(cam.forward) vs \(f)")
            XCTAssertTrue(cam.position.isApproximatelyEqual(to: p, tolerance: 1e-5))
            XCTAssertEqual(cam.camera.fieldOfView, .pi / 2, accuracy: 1e-6)
            XCTAssertEqual(cam.aspect, 1)
            let basis = Mat3(columns: cam.world.c0.xyz, cam.world.c1.xyz, cam.world.c2.xyz)
            XCTAssertEqual(basis.determinant, -1, accuracy: 1e-5, "cube faces use a left-handed frame")
        }
        // A point straight ahead of each face projects to the centre of the image.
        for (cam, f) in zip(cams, forwards) {
            let clip = cam.viewProjection * Vec4(p + f * 10, 1)
            XCTAssertEqual(clip.x / clip.w, 0, accuracy: 1e-4)
            XCTAssertEqual(clip.y / clip.w, 0, accuracy: 1e-4)
        }
    }

    // Near and far are kept valid even for nonsense input.
    func testCubeFaceCamerasClampRange() {
        let cam = FrameUniformsBuilder.cubeFaceCameras(position: .zero, near: 0, far: -5)[0].camera
        XCTAssertGreaterThan(cam.near, 0)
        XCTAssertGreaterThan(cam.far, cam.near)
    }
}

final class PostUniformsTests: XCTestCase {
    // Tone mapper indices match the switch in tonemapFragment.
    func testOperatorIndices() {
        XCTAssertEqual(PostUniformsBuilder.operatorIndex(.none), 0)
        XCTAssertEqual(PostUniformsBuilder.operatorIndex(.reinhard), 1)
        XCTAssertEqual(PostUniformsBuilder.operatorIndex(.aces), 2)
        XCTAssertEqual(PostUniformsBuilder.operatorIndex(.agx), 3)
    }

    // The focal length reproduces the field of view on a 24 mm sensor.
    func testFocalLength() {
        for degrees: Float in [20, 45, 60, 90] {
            let fov = degrees * .pi / 180
            let f = PostUniformsBuilder.focalLength(fovY: fov)
            XCTAssertEqual(2 * atan(PostUniformsBuilder.sensorHeight / (2 * f)), fov, accuracy: 1e-4)
        }
        XCTAssertTrue(PostUniformsBuilder.focalLength(fovY: 0).isFinite)
    }

    // Bloom mips stop before the smaller side drops below 8 px, between 1 and 7 levels.
    func testBloomMipCount() {
        XCTAssertEqual(PostUniformsBuilder.bloomMipCount(width: 1920, height: 1080), 7)
        XCTAssertEqual(PostUniformsBuilder.bloomMipCount(width: 16, height: 16), 1)
        XCTAssertEqual(PostUniformsBuilder.bloomMipCount(width: 4, height: 4), 1)
        XCTAssertEqual(PostUniformsBuilder.bloomMipCount(width: 0, height: 0), 1)
    }

    // Settings map onto the uniform fields, with disabled bloom contributing nothing.
    func testSettingsMapping() {
        var s = PostProcessSettings()
        s.toneMapper = .aces
        s.colorGrading.exposure = 1
        s.colorGrading.vignette = 3
        s.bloom.enabled = false
        s.autoExposure = true
        var aa = AntiAliasingSettings()
        aa.taaFeedback = 0
        aa.sharpness = 2
        let p = PostUniformsBuilder.make(s, antiAliasing: aa, camera: nil, frameIndex: 2000, deltaTime: -1)
        XCTAssertEqual(p.tonemap.x, 2)
        XCTAssertEqual(p.tonemap.y, 2, accuracy: 1e-6, "exposure is in stops")
        XCTAssertEqual(p.bloom.z, 0)
        XCTAssertEqual(p.whiteBalance.w, 1, "vignette is clamped to 1")
        XCTAssertEqual(p.lift.w, 1, "auto exposure flag")
        XCTAssertEqual(p.taa.x, 0.02, accuracy: 1e-6, "TAA feedback has a floor")
        XCTAssertEqual(p.sharpen.x, 1)
        XCTAssertEqual(p.misc.x, 976, "frame index wraps at 1024")
        XCTAssertEqual(p.misc.y, 0, "negative delta time is clamped")
    }

    // Motion blur sample counts are clamped to 2...32.
    func testMotionBlurSampleClamp() {
        var s = PostProcessSettings()
        s.motionBlur.samples = 500
        XCTAssertEqual(
            PostUniformsBuilder.make(
                s, antiAliasing: AntiAliasingSettings(), camera: nil,
                frameIndex: 0, deltaTime: 0.016
            ).motionBlur.y, 32)
        s.motionBlur.samples = 0
        XCTAssertEqual(
            PostUniformsBuilder.make(
                s, antiAliasing: AntiAliasingSettings(), camera: nil,
                frameIndex: 0, deltaTime: 0.016
            ).motionBlur.y, 2)
    }

    // Depth of field uses the camera's field of view when one is given.
    func testDepthOfFieldUsesCameraFOV() {
        let cam = Camera.perspective(fov: 30)
        let p = PostUniformsBuilder.make(
            PostProcessSettings(), antiAliasing: AntiAliasingSettings(), camera: cam,
            frameIndex: 0, deltaTime: 0)
        XCTAssertEqual(p.dof.z, PostUniformsBuilder.focalLength(fovY: cam.fieldOfView), accuracy: 1e-6)
    }
}

final class DynamicResolutionTests: XCTestCase {
    func enabledSettings() -> DynamicResolutionSettings {
        var s = DynamicResolutionSettings()
        s.enabled = true
        s.minScale = 0.5
        s.maxScale = 1
        return s
    }

    // A disabled controller never changes scale.
    func testDisabledKeepsScale() {
        var c = DynamicResolutionController(settings: DynamicResolutionSettings())
        for _ in 0..<100 { c.update(gpuMilliseconds: 100, budgetMs: 10) }
        XCTAssertEqual(c.scale, 1)
    }

    // The initial scale is clamped to the configured range.
    func testInitialScaleClamped() {
        XCTAssertEqual(DynamicResolutionController(settings: enabledSettings(), initialScale: 3).scale, 1)
        XCTAssertEqual(DynamicResolutionController(settings: enabledSettings(), initialScale: 0.1).scale, 0.5)
    }

    // Over budget the scale drops at once towards the pixel-count estimate, then holds
    // through the cool-down.
    func testDropsQuicklyThenCoolsDown() {
        var c = DynamicResolutionController(settings: enabledSettings())
        let first = c.update(gpuMilliseconds: 20, budgetMs: 10)
        XCTAssertEqual(first, 0.7, accuracy: 1e-4, "√(10/20) ≈ 0.707, quantised down to 0.70")
        for _ in 0..<c.cooldownFrames { XCTAssertEqual(c.update(gpuMilliseconds: 40, budgetMs: 10), first) }
        XCTAssertLessThan(c.update(gpuMilliseconds: 40, budgetMs: 10), first)
    }

    // With plenty of headroom the scale climbs back in single steps and stops at the maximum.
    func testRecoversSlowlyToMax() {
        var c = DynamicResolutionController(settings: enabledSettings(), initialScale: 0.5)
        var previous = c.scale
        for _ in 0..<1000 {
            let s = c.update(gpuMilliseconds: 2, budgetMs: 16)
            XCTAssertLessThanOrEqual(s - previous, c.step + 1e-4, "never more than one step up")
            previous = s
        }
        XCTAssertEqual(c.scale, 1, accuracy: 1e-4)
    }

    // The scale never leaves [minScale, maxScale], and invalid timings are ignored.
    func testStaysInRangeAndIgnoresBadTimings() {
        var c = DynamicResolutionController(settings: enabledSettings())
        for _ in 0..<500 { c.update(gpuMilliseconds: 1000, budgetMs: 1) }
        XCTAssertEqual(c.scale, 0.5, accuracy: 1e-4)
        let before = c.scale
        c.update(gpuMilliseconds: .nan, budgetMs: 16)
        c.update(gpuMilliseconds: .infinity, budgetMs: 16)
        c.update(gpuMilliseconds: -3, budgetMs: 16)
        XCTAssertEqual(c.scale, before)
    }

    // An explicit GPU target overrides the caller's budget.
    func testExplicitTargetOverridesBudget() {
        var s = enabledSettings()
        s.targetGPUMilliseconds = 30
        var c = DynamicResolutionController(settings: s)
        c.update(gpuMilliseconds: 20, budgetMs: 10)  // within the 30 ms target
        XCTAssertEqual(c.scale, 1)
    }
}
