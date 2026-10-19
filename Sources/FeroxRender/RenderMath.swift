import FeroxCore
import Foundation

/// Pure rendering maths shared by the Metal backend and the unit tests. Nothing here
/// touches Metal, so it is exercised on every platform CI runs on.
public enum RenderMath {
    // MARK: Temporal jitter

    /// Radical inverse of `index` in `base` (Halton sequence), in [0, 1).
    public static func halton(_ index: Int, base: Int) -> Float {
        precondition(base >= 2, "Halton base must be at least 2")
        var f: Float = 1
        var r: Float = 0
        var i = max(index, 0)
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }

    /// Sub-pixel jitter for `frame`, in clip-space units (2 / size per pixel), cycling
    /// through `phases` points of the Halton(2, 3) sequence. Index 0 is skipped because
    /// it is the pixel corner (0, 0) for every base.
    public static func jitter(frame: UInt64, phases: Int, renderWidth: Int, renderHeight: Int) -> Vec2 {
        let n = max(phases, 1)
        let i = Int(frame % UInt64(n)) + 1
        let px = halton(i, base: 2) - 0.5
        let py = halton(i, base: 3) - 0.5
        return Vec2(px * 2 / Float(max(renderWidth, 1)), py * 2 / Float(max(renderHeight, 1)))
    }

    // MARK: Cascaded shadow maps

    /// View-space split distances using the "practical" scheme (Zhang et al. 2006): a
    /// blend of logarithmic and uniform splits. Returns `count + 1` values from `near` to
    /// `far`.
    public static func cascadeSplits(near: Float, far: Float, count: Int, lambda: Float = 0.75) -> [Float] {
        let n = max(near, 1e-3)
        let f = max(far, n + 1e-3)
        let c = min(max(count, 1), 4)
        var splits = [n]
        for i in 1...c {
            let p = Float(i) / Float(c)
            let log = n * pow(f / n, p)
            let uni = n + (f - n) * p
            splits.append(lambda * log + (1 - lambda) * uni)
        }
        splits[c] = f
        return splits
    }

    /// World-space corners of the camera frustum slice between view depths `d0` and `d1`.
    ///
    /// `inverseViewProjection` must be the (unjittered) camera matrix; `near`/`far` are the
    /// camera's clip distances. Corners on one frustum edge are interpolated linearly in view
    /// depth, which is exact for both perspective and orthographic projections.
    public static func frustumSliceCorners(
        inverseViewProjection inv: Mat4, near: Float, far: Float,
        from d0: Float, to d1: Float
    ) -> [Vec3] {
        let range = max(far - near, 1e-4)
        let t0 = (d0 - near) / range
        let t1 = (d1 - near) / range
        var out: [Vec3] = []
        out.reserveCapacity(8)
        for y in [Float(-1), 1] {
            for x in [Float(-1), 1] {
                // Reverse-Z: NDC z = 1 is the near plane, 0 the far plane.
                let pn = inv.transformPoint(Vec3(x, y, 1))
                let pf = inv.transformPoint(Vec3(x, y, 0))
                out.append(pn.lerp(to: pf, t0))
                out.append(pn.lerp(to: pf, t1))
            }
        }
        return out
    }

    /// A stable (rotation- and translation-invariant) orthographic light matrix that covers
    /// `corners`. The slice is bounded by a sphere whose radius is quantised, and the
    /// projection is snapped to whole shadow-map texels, so shadows do not shimmer when
    /// the camera moves. Uses standard (not reversed) depth; shadow passes compare `less`.
    ///
    /// - Parameters:
    ///   - towardsLight: unit vector pointing from the scene towards the light.
    ///   - casterDistance: extra depth behind the slice so off-screen casters still cast.
    public static func stableCascadeMatrix(
        corners: [Vec3], towardsLight: Vec3, resolution: Int,
        casterDistance: Float = 100
    ) -> Mat4 {
        guard !corners.isEmpty else { return .identity }
        var center = Vec3.zero
        for c in corners { center += c }
        center /= Float(corners.count)
        var radius: Float = 0
        for c in corners { radius = max(radius, c.distance(to: center)) }
        radius = max((radius * 16).rounded(.up) / 16, 0.01)

        let dir = towardsLight.lengthSquared > 1e-8 ? towardsLight.normalized : Vec3.up
        let up = abs(dir.dot(.up)) > 0.99 ? Vec3(0, 0, 1) : Vec3.up
        let eye = center + dir * (radius + casterDistance)
        let view = Mat4.lookAt(eye: eye, target: center, up: up)
        let proj = Mat4.orthographic(
            left: -radius, right: radius, bottom: -radius, top: radius,
            near: 0, far: 2 * radius + casterDistance, reverseZ: false)
        var vp = proj * view

        // Snap the world origin to the texel grid.
        let res = Float(max(resolution, 1))
        let origin = vp * Vec4(0, 0, 0, 1)
        let texel = Vec2(origin.x, origin.y) * (res * 0.5)
        let rounded = Vec2(texel.x.rounded(), texel.y.rounded())
        let offset = (rounded - texel) * (2 / res)
        vp = Mat4.translation(Vec3(offset.x, offset.y, 0)) * vp
        return vp
    }

    // MARK: Exposure & colour

    /// Photometric exposure for an EV100 value (Lagarde & de Rousiers 2014, saturation-based
    /// sensitivity): `1 / (1.2 · 2^EV100)`.
    public static func exposure(ev100: Float) -> Float { 1 / (1.2 * pow(2, ev100)) }

    /// LMS scale factors for a white-balance adjustment. `temperature` and `tint` are in
    /// [-100, 100]; zero for both is the identity. The coefficients follow the widely used
    /// CIE-xy-to-LMS formulation (CAT02-style cone response) relative to D65.
    public static func whiteBalanceLMS(temperature: Float, tint: Float) -> Vec3 {
        let t1 = min(max(temperature, -100), 100) / 65
        let t2 = min(max(tint, -100), 100) / 65
        let x = 0.31271 - t1 * (t1 < 0 ? 0.1 : 0.05)
        let standardY = 2.87 * x - 3 * x * x - 0.27509507
        let y = standardY + t2 * 0.05
        let w1 = Vec3(0.949237, 1.03542, 1.08728)  // D65 white in LMS
        let w2 = cieXYToLMS(x: x, y: y)
        return Vec3(w1.x / w2.x, w1.y / w2.y, w1.z / w2.z)
    }

    static func cieXYToLMS(x: Float, y: Float) -> Vec3 {
        let yy: Float = 1
        let xx = yy * x / y
        let zz = yy * (1 - x - y) / y
        let l = 0.7328 * xx + 0.4296 * yy - 0.1624 * zz
        let m = -0.7036 * xx + 1.6975 * yy + 0.0061 * zz
        let s = 0.0030 * xx + 0.0136 * yy + 0.9834 * zz
        return Vec3(l, m, s)
    }

    // MARK: Clustered lighting

    /// `FrameUniforms.clusterParams` for exponential depth slicing: the shader computes
    /// `slice = log(depth) * z - w`, so slice 0 starts at `near` and slice `slices` ends at
    /// `far`.
    public static func clusterParams(near: Float, far: Float, slices: Int) -> Vec4 {
        let n = max(near, 1e-3)
        let f = max(far, n * 1.001)
        let scale = Float(max(slices, 1)) / log(f / n)
        return Vec4(n, f, scale, scale * log(n))
    }

    /// The cluster slice a view depth falls into (mirror of the shader, for tests).
    public static func clusterSlice(viewDepth: Float, params: Vec4, slices: Int) -> Int {
        let s = log(max(viewDepth, 1e-3)) * params.z - params.w
        return min(Int(max(s, 0)), max(slices, 1) - 1)
    }

    // MARK: Culling & LOD

    /// Fraction of the screen height covered by a bounding sphere (perspective), used for
    /// LOD selection. Orthographic cameras pass their half-height as `orthoSize`.
    public static func screenHeightFraction(
        radius: Float, distance: Float, fovY: Float,
        orthoSize: Float? = nil
    ) -> Float {
        if let o = orthoSize { return radius / max(o, 1e-4) }
        let d = max(distance, 1e-4)
        return radius / (d * tan(fovY * 0.5))
    }

    /// Frustum planes packed for `CullUniforms` (xyz normal, w distance), normalised.
    public static func packedPlanes(_ f: Frustum) -> (Vec4, Vec4, Vec4, Vec4, Vec4, Vec4) {
        var p = [Vec4](repeating: .zero, count: 6)
        for (i, plane) in f.planes.prefix(6).enumerated() {
            let len = max(plane.normal.length, 1e-8)
            p[i] = Vec4(plane.normal / len, plane.d / len)
        }
        return (p[0], p[1], p[2], p[3], p[4], p[5])
    }

    /// Transforms a local bounding box into a world-space bounding sphere.
    public static func boundingSphere(_ box: AABB, _ m: Mat4) -> Sphere {
        guard !box.isEmpty else { return Sphere(center: m.translation, radius: 0) }
        let c = m.transformAffine(box.center)
        let sx = m.c0.xyz.length
        let sy = m.c1.xyz.length
        let sz = m.c2.xyz.length
        let r = box.extents.length * max(sx, max(sy, sz))
        return Sphere(center: c, radius: r)
    }

    /// Mip count of a full chain for a `w`×`h` texture.
    public static func mipCount(_ w: Int, _ h: Int) -> Int {
        var n = 1
        var s = max(w, h)
        while s > 1 {
            s >>= 1
            n += 1
        }
        return n
    }

    /// Dispatch size helper: ceil(n / group). Negative counts give 0; a group size below
    /// one is treated as one.
    public static func groups(_ n: Int, _ group: Int) -> Int {
        let g = max(group, 1)
        return (max(n, 0) + g - 1) / g
    }
}

// MARK: Reflection probes

extension RenderMath {
    /// Smallest and largest probe face edge, in texels. All probes share one cube array,
    /// so the largest `ReflectionProbe.resolution` in the scene decides the size for all.
    public static let probeFaceSizeRange = 32...256

    /// The shared probe face size for the requested resolutions: the largest request,
    /// rounded up to a power of two and clamped to `probeFaceSizeRange`. With no probes
    /// the current size is kept, so probes coming and going do not reallocate the array.
    public static func probeFaceSize(requested: [Int], current: Int) -> Int {
        guard let largest = requested.max() else { return current }
        var size = probeFaceSizeRange.lowerBound
        while size < min(largest, probeFaceSizeRange.upperBound) { size *= 2 }
        return min(size, probeFaceSizeRange.upperBound)
    }
}

// MARK: Camera viewport

/// A camera's viewport in output pixels (origin top-left, y down, as Metal's viewport).
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension RenderMath {
    /// Converts `Camera.viewport` (normalised, origin at the top-left of the output) to
    /// whole output pixels. The rectangle is clipped to the output and is never smaller
    /// than 1 × 1, so a degenerate or off-screen viewport still renders something valid.
    public static func viewportPixels(_ viewport: Rect, outputWidth: Int, outputHeight: Int) -> PixelRect {
        let w = max(outputWidth, 1)
        let h = max(outputHeight, 1)
        func clamp01(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }
        let x0 = clamp01(viewport.minX)
        let y0 = clamp01(viewport.minY)
        let x1 = clamp01(viewport.minX + viewport.size.x)
        let y1 = clamp01(viewport.minY + viewport.size.y)
        let px = min(Int((x0 * Float(w)).rounded()), w - 1)
        let py = min(Int((y0 * Float(h)).rounded()), h - 1)
        let pw = max(Int((x1 * Float(w)).rounded()) - px, 1)
        let ph = max(Int((y1 * Float(h)).rounded()) - py, 1)
        return PixelRect(x: px, y: py, width: min(pw, w - px), height: min(ph, h - py))
    }
}
