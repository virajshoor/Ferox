import FeroxCore
import Foundation

/// Scene and post GPU times for the frames the CPU has in flight.
///
/// Metal completion handlers run off the thread that encoded the frame. They must not
/// capture `Renderer`: it is not `Sendable`. This clock is the value they share. The
/// lock is the synchronisation; `@unchecked Sendable` records that.
public final class GPUFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sceneMilliseconds: [Double]
    private var latest: Double?

    public init(framesInFlight: Int) {
        sceneMilliseconds = Array(repeating: 0, count: max(framesInFlight, 1))
    }

    /// Stores the scene pass time for `slot`. A later `recordPost` reads it.
    public func recordScene(slot: Int, milliseconds: Double) {
        lock.locked {
            guard sceneMilliseconds.indices.contains(slot) else { return }
            sceneMilliseconds[slot] = milliseconds
        }
    }

    /// Adds the post pass to the scene time for `slot`. When the sum is positive it
    /// becomes the last completed frame time. Returns the sum, or 0 for an unknown slot.
    public func recordPost(slot: Int, postMilliseconds: Double) -> Double {
        lock.locked {
            guard sceneMilliseconds.indices.contains(slot) else { return 0 }
            let total = sceneMilliseconds[slot] + postMilliseconds
            if total > 0 { latest = total }
            return total
        }
    }

    /// The last positive scene-plus-post sample, or nil before the first one.
    public func lastMilliseconds() -> Double? {
        lock.locked { latest }
    }
}
