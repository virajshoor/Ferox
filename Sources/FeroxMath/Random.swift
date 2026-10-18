import Foundation

/// PCG32 random number generator (O'Neill 2014). Deterministic for a given seed and
/// stream on every platform, which makes it suitable for replays, networking and tests.
public struct PCG32: RandomNumberGenerator, Hashable, Codable, Sendable {
    private var state: UInt64
    private var inc: UInt64

    public init(seed: UInt64, stream: UInt64 = 0xDA3E_39CB_94B9_5BDB) {
        state = 0
        inc = (stream << 1) | 1
        _ = nextUInt32()
        state &+= seed
        _ = nextUInt32()
    }

    public mutating func nextUInt32() -> UInt32 {
        let old = state
        state = old &* 6_364_136_223_846_793_005 &+ inc
        let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((~rot &+ 1) & 31))
    }

    public mutating func next() -> UInt64 {
        (UInt64(nextUInt32()) << 32) | UInt64(nextUInt32())
    }

    /// Uniform float in [0, 1).
    public mutating func nextFloat() -> Float { Float(nextUInt32() >> 8) * (1 / Float(1 << 24)) }
    /// Uniform float in [lo, hi).
    public mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextFloat()
    }
    /// Uniformly distributed unit vector on the sphere.
    public mutating func nextUnitVector() -> Vec3 {
        let z = nextFloat() * 2 - 1
        let a = nextFloat() * 2 * .pi
        let r = (1 - z * z).squareRoot()
        return Vec3(r * cos(a), r * sin(a), z)
    }
    /// Uniform point inside the unit disc.
    public mutating func nextInUnitDisc() -> Vec2 {
        let r = nextFloat().squareRoot()
        let a = nextFloat() * 2 * .pi
        return Vec2(r * cos(a), r * sin(a))
    }
}

/// Low-discrepancy Halton sequence, used for TAA sub-pixel jitter and sampling.
public enum Halton {
    public static func value(index: Int, base: Int) -> Float {
        var f: Float = 1, r: Float = 0
        var i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }

    /// The `index`-th point of the (2, 3) Halton sequence, centred on zero in [-0.5, 0.5).
    public static func jitter(index: Int) -> Vec2 {
        Vec2(value(index: index + 1, base: 2) - 0.5, value(index: index + 1, base: 3) - 0.5)
    }
}
