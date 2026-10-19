import Foundation

/// One shape on one body. Shape indices are stored in full: a compound with 256 or more
/// shapes does not alias shape 0 the way an 8-bit packed key did.
struct ShapeRef: Hashable, Comparable, Sendable {
    var body: Int
    var shape: Int

    static func < (lhs: ShapeRef, rhs: ShapeRef) -> Bool {
        lhs.body != rhs.body ? lhs.body < rhs.body : lhs.shape < rhs.shape
    }
}

/// Canonical unordered pair of shape references. The contact map uses this instead of
/// packing each side into 32 bits, so neither the body index nor the shape index is truncated.
struct ContactKey: Hashable, Comparable, Sendable {
    var lo: ShapeRef
    var hi: ShapeRef

    init(_ a: ShapeRef, _ b: ShapeRef) {
        if a <= b {
            lo = a
            hi = b
        } else {
            lo = b
            hi = a
        }
    }

    init(bodyA: Int, shapeA: Int, bodyB: Int, shapeB: Int) {
        self.init(ShapeRef(body: bodyA, shape: shapeA), ShapeRef(body: bodyB, shape: shapeB))
    }

    static func < (lhs: ContactKey, rhs: ContactKey) -> Bool {
        lhs.lo != rhs.lo ? lhs.lo < rhs.lo : lhs.hi < rhs.hi
    }
}
