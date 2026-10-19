/// Translation-rotation-scale value used for local and world transforms.
@frozen
public struct TRS: Hashable, Codable, Sendable {
    public var position: Vec3
    public var rotation: Quat
    public var scale: Vec3

    @inlinable public init(position: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = Vec3(1, 1, 1)) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }
    public static let identity = TRS()

    @inlinable public var matrix: Mat4 { Mat4(translation: position, rotation: rotation, scale: scale) }

    @inlinable public var forward: Vec3 { rotation.act(.forward) }
    @inlinable public var right: Vec3 { rotation.act(.right) }
    @inlinable public var up: Vec3 { rotation.act(.up) }

    /// Interpolates position/scale linearly and rotation with nlerp — used for render-time
    /// interpolation between fixed simulation steps.
    @inlinable public func interpolated(to b: TRS, _ t: Float) -> TRS {
        TRS(
            position: position.lerp(to: b.position, t), rotation: rotation.nlerp(to: b.rotation, t),
            scale: scale.lerp(to: b.scale, t))
    }

    /// Composition `parent * child` (exact when scales are uniform; non-uniform scale with
    /// rotation produces shear that TRS cannot represent, so use matrices for that case).
    @inlinable public static func * (p: TRS, c: TRS) -> TRS {
        TRS(
            position: p.position + p.rotation.act(p.scale * c.position), rotation: p.rotation * c.rotation,
            scale: p.scale * c.scale)
    }

    public init(matrix: Mat4) {
        let d = matrix.decompose()
        self.init(position: d.translation, rotation: d.rotation, scale: d.scale)
    }
}
