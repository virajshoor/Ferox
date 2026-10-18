import FeroxCore
import Foundation

/// A value that can be interpolated by animation curves.
public protocol Interpolatable: Sendable, Codable, Hashable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Float) -> Self
    /// Cubic Hermite interpolation used by glTF CUBICSPLINE samplers.
    static func hermite(_ p0: Self, _ m0: Self, _ p1: Self, _ m1: Self, _ t: Float, _ dt: Float) -> Self
}

extension Float: Interpolatable {
    public static func interpolate(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    public static func hermite(_ p0: Float, _ m0: Float, _ p1: Float, _ m1: Float, _ t: Float, _ dt: Float) -> Float {
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        return h00 * p0 + h10 * dt * m0 + h01 * p1 + h11 * dt * m1
    }
}

extension SIMD3: Interpolatable where Scalar == Float {
    public static func interpolate(_ a: Self, _ b: Self, _ t: Float) -> Self { a + (b - a) * t }
    public static func hermite(_ p0: Self, _ m0: Self, _ p1: Self, _ m1: Self, _ t: Float, _ dt: Float) -> Self {
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        return p0 * h00 + m0 * (h10 * dt) + p1 * h01 + m1 * (h11 * dt)
    }
}

extension SIMD4: Interpolatable where Scalar == Float {
    public static func interpolate(_ a: Self, _ b: Self, _ t: Float) -> Self { a + (b - a) * t }
    public static func hermite(_ p0: Self, _ m0: Self, _ p1: Self, _ m1: Self, _ t: Float, _ dt: Float) -> Self {
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        return p0 * h00 + m0 * (h10 * dt) + p1 * h01 + m1 * (h11 * dt)
    }
}

extension Quat: Interpolatable {
    public static func interpolate(_ a: Quat, _ b: Quat, _ t: Float) -> Quat { a.slerp(to: b, t) }
    public static func hermite(_ p0: Quat, _ m0: Quat, _ p1: Quat, _ m1: Quat, _ t: Float, _ dt: Float) -> Quat {
        Quat(Vec4.hermite(p0.vector, m0.vector, p1.vector, m1.vector, t, dt)).normalized
    }
}

extension Color: Interpolatable {
    public static func interpolate(_ a: Color, _ b: Color, _ t: Float) -> Color { a.lerp(to: b, t) }
    public static func hermite(_ p0: Color, _ m0: Color, _ p1: Color, _ m1: Color, _ t: Float, _ dt: Float) -> Color {
        Color(Vec4.hermite(p0.vector, m0.vector, p1.vector, m1.vector, t, dt))
    }
}

public enum CurveInterpolation: String, Codable, Sendable, CaseIterable { case step, linear, cubic }

/// A keyframed curve. Keys must be sorted by time (enforced on construction).
public struct AnimationCurve<Value: Interpolatable>: Codable, Hashable, Sendable {
    public struct Key: Codable, Hashable, Sendable {
        public var time: Float
        public var value: Value
        /// Tangents for cubic interpolation (glTF in/out tangents).
        public var inTangent: Value?
        public var outTangent: Value?
        public init(_ time: Float, _ value: Value, inTangent: Value? = nil, outTangent: Value? = nil) {
            self.time = time
            self.value = value
            self.inTangent = inTangent
            self.outTangent = outTangent
        }
    }
    public private(set) var keys: [Key]
    public var interpolation: CurveInterpolation

    public init(keys: [Key], interpolation: CurveInterpolation = .linear) {
        self.keys = keys.sorted { $0.time < $1.time }
        self.interpolation = interpolation
    }

    public var duration: Float { keys.last?.time ?? 0 }
    public var startTime: Float { keys.first?.time ?? 0 }

    /// Index of the last key with time <= t (binary search).
    func segment(_ t: Float) -> Int {
        var lo = 0, hi = keys.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keys[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func sample(_ t: Float) -> Value? {
        guard let first = keys.first else { return nil }
        if keys.count == 1 || t <= first.time { return first.value }
        let last = keys[keys.count - 1]
        if t >= last.time { return last.value }
        let i = segment(t)
        let a = keys[i], b = keys[i + 1]
        let dt = b.time - a.time
        let u = dt > 0 ? (t - a.time) / dt : 0
        switch interpolation {
        case .step: return a.value
        case .linear: return Value.interpolate(a.value, b.value, u)
        case .cubic:
            guard let m0 = a.outTangent, let m1 = b.inTangent else { return Value.interpolate(a.value, b.value, u) }
            return Value.hermite(a.value, m0, b.value, m1, u, dt)
        }
    }
}

/// Standard easing functions (Robert Penner), parameter and result in [0, 1].
public enum Easing: String, Codable, Sendable, CaseIterable {
    case linear, easeInQuad, easeOutQuad, easeInOutQuad, easeInCubic, easeOutCubic, easeInOutCubic
    case easeInSine, easeOutSine, easeInOutSine, easeOutBack, easeOutElastic, easeOutBounce

    public func apply(_ x: Float) -> Float {
        let t = x.saturated
        switch self {
        case .linear: return t
        case .easeInQuad: return t * t
        case .easeOutQuad: return 1 - (1 - t) * (1 - t)
        case .easeInOutQuad: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .easeInCubic: return t * t * t
        case .easeOutCubic: return 1 - pow(1 - t, 3)
        case .easeInOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .easeInSine: return 1 - cos(t * .pi / 2)
        case .easeOutSine: return sin(t * .pi / 2)
        case .easeInOutSine: return -(cos(.pi * t) - 1) / 2
        case .easeOutBack:
            let c1: Float = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .easeOutElastic:
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
        case .easeOutBounce:
            let n1: Float = 7.5625, d1: Float = 2.75
            var u = t
            if u < 1 / d1 { return n1 * u * u }
            if u < 2 / d1 {
                u -= 1.5 / d1
                return n1 * u * u + 0.75
            }
            if u < 2.5 / d1 {
                u -= 2.25 / d1
                return n1 * u * u + 0.9375
            }
            u -= 2.625 / d1
            return n1 * u * u + 0.984375
        }
    }
}
