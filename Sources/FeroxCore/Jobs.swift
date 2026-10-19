import Foundation

/// Lightweight data-parallel job helpers built on Grand Central Dispatch.
///
/// GCD's `concurrentPerform` maps work onto a pool sized to the active CPU cores, which on
/// Apple Silicon includes both performance and efficiency cores. Work is split into
/// contiguous chunks so each worker touches a cache-friendly range of memory.
public enum Jobs {
    /// Number of worker threads the system will use for parallel loops.
    public static var workerCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// Runs `body(range)` over `0..<count` split into chunks of at least `minChunk` items.
    /// Executes inline when the workload is too small to be worth parallelising.
    ///
    /// `body` is `@Sendable`. Capture only values that are safe to use from several
    /// workers at once, such as integers and buffers whose ranges do not overlap.
    /// Do not capture a `World` or a component store.
    public static func parallelFor(count: Int, minChunk: Int = 256, _ body: @Sendable (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let workers = max(1, workerCount)
        let chunk = max(minChunk, (count + workers - 1) / workers)
        let chunks = (count + chunk - 1) / chunk
        if chunks <= 1 {
            body(0..<count)
            return
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { i in
            let lo = i * chunk
            body(lo..<min(lo + chunk, count))
        }
    }
}

/// Serial background queue for I/O-bound work (asset decoding, file watching) whose results
/// are delivered back on the main thread via `ThreadSafeQueue` or `MainThreadDispatcher`.
public final class BackgroundWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let group = DispatchGroup()

    public init(label: String, qos: DispatchQoS = .utility, concurrent: Bool = false) {
        queue = DispatchQueue(label: label, qos: qos, attributes: concurrent ? .concurrent : [])
    }

    public func submit(_ work: @escaping @Sendable () -> Void) {
        queue.async(group: group, execute: work)
    }

    /// Blocks until all submitted work completes. Never call from the render thread.
    public func waitUntilIdle() { group.wait() }
}

/// Collects closures from any thread and runs them on the main thread at a defined point
/// in the frame (the engine drains it right after input polling).
public final class MainThreadDispatcher: @unchecked Sendable {
    public static let shared = MainThreadDispatcher()
    private let queue = ThreadSafeQueue<() -> Void>()
    public init() {}
    public func post(_ work: @escaping () -> Void) { queue.push(work) }
    /// Runs all pending closures. Must be called on the main thread.
    public func drain() {
        for w in queue.drain() { w() }
    }
}
