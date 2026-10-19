import Foundation

/// Marker protocol for event payloads dispatched through an `EventBus`.
public protocol Event {}

/// Token returned by `EventBus.subscribe`; cancel it (or drop all references to the bus)
/// to stop receiving events.
public struct Subscription: Hashable, Sendable {
    public let id: UInt64
    fileprivate let typeKey: ObjectIdentifier
}

/// Synchronous, type-keyed publish/subscribe bus.
///
/// Two delivery modes are offered:
/// - `publish` delivers immediately to all subscribers, in subscription order.
/// - `enqueue` defers delivery until `flush()`, which the engine calls once per frame
///   after the fixed-step simulation. Use it for events raised from inside iteration
///   (physics callbacks, ECS queries) where immediate re-entry would be unsafe.
///
/// The bus is designed for main-thread game code and is not thread-safe; use
/// `ThreadSafeEventQueue` to hand events from worker threads to the main thread.
public final class EventBus {
    private struct Handler {
        let id: UInt64
        let call: (Any) -> Void
    }
    private var handlers: [ObjectIdentifier: [Handler]] = [:]
    private var queued: [(ObjectIdentifier, Any)] = []
    private var nextID: UInt64 = 1
    private var dispatchDepth = 0
    private var pendingRemovals: [Subscription] = []

    public init() {}

    @discardableResult
    public func subscribe<E: Event>(_ type: E.Type, _ handler: @escaping (E) -> Void) -> Subscription {
        let key = ObjectIdentifier(type)
        let id = nextID
        nextID += 1
        handlers[key, default: []].append(
            Handler(id: id) { any in
                if let e = any as? E { handler(e) }
            })
        return Subscription(id: id, typeKey: key)
    }

    public func unsubscribe(_ s: Subscription) {
        if dispatchDepth > 0 {
            pendingRemovals.append(s)
            return
        }
        handlers[s.typeKey]?.removeAll { $0.id == s.id }
    }

    public func publish<E: Event>(_ event: E) {
        dispatch(ObjectIdentifier(E.self), event)
    }

    public func enqueue<E: Event>(_ event: E) { queued.append((ObjectIdentifier(E.self), event)) }

    /// Upper bound on events delivered by one `flush()`. A handler that enqueues an event
    /// every time it runs would otherwise keep a flush going forever; anything past the cap
    /// is kept for the next flush and a warning is logged.
    public var maxEventsPerFlush = 65_536

    private var isFlushing = false

    /// Delivers all queued events. Events enqueued during the flush are delivered in the same
    /// flush, up to `maxEventsPerFlush`. A nested `flush()` from inside a handler does nothing.
    public func flush() {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let limit = max(maxEventsPerFlush, 1)
        var i = 0
        while i < queued.count && i < limit {
            let (key, e) = queued[i]
            dispatch(key, e)
            i += 1
        }
        if i < queued.count {
            Log.warning("Events", "flush delivered \(i) events and deferred \(queued.count - i) to the next flush")
            queued.removeFirst(i)
        } else {
            queued.removeAll(keepingCapacity: true)
        }
    }

    public var queuedCount: Int { queued.count }

    public func subscriberCount<E: Event>(for type: E.Type) -> Int { handlers[ObjectIdentifier(type)]?.count ?? 0 }

    private func dispatch(_ key: ObjectIdentifier, _ event: Any) {
        guard let list = handlers[key], !list.isEmpty else { return }
        dispatchDepth += 1
        for h in list { h.call(event) }
        dispatchDepth -= 1
        if dispatchDepth == 0 && !pendingRemovals.isEmpty {
            let removals = pendingRemovals
            pendingRemovals.removeAll()
            for s in removals { unsubscribe(s) }
        }
    }
}

/// Multi-producer queue for handing values to a single consumer (usually the main thread).
public final class ThreadSafeQueue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    public init() {}
    public func push(_ item: T) { lock.locked { items.append(item) } }
    /// Removes and returns every queued item.
    public func drain() -> [T] {
        lock.locked {
            let out = items
            items.removeAll(keepingCapacity: true)
            return out
        }
    }
    public var count: Int { lock.locked { items.count } }
}
