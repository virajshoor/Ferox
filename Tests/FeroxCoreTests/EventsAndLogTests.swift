/// Tests for the synchronous `EventBus` (publish, enqueue and flush, subscription lifetime),
/// the structured `Log` with its ring-buffer sink, and the thread-safe hand-off queues.
import Foundation
import XCTest

@testable import FeroxCore

private struct TestPing: Event {
    let value: Int
}

private struct TestPong: Event {
    let text: String
}

final class EventBusTests: XCTestCase {
    // publish delivers to every subscriber of the type, in subscription order.
    func testPublishDeliversInSubscriptionOrder() {
        let bus = EventBus()
        var order: [String] = []
        bus.subscribe(TestPing.self) { _ in order.append("first") }
        bus.subscribe(TestPing.self) { _ in order.append("second") }
        bus.publish(TestPing(value: 1))
        XCTAssertEqual(order, ["first", "second"])
    }

    // Subscribers only receive events of the type they subscribed to.
    func testSubscriptionsAreKeyedByType() {
        let bus = EventBus()
        var pings = 0
        bus.subscribe(TestPing.self) { _ in pings += 1 }
        bus.publish(TestPong(text: "hello"))
        XCTAssertEqual(pings, 0)
        XCTAssertEqual(bus.subscriberCount(for: TestPing.self), 1)
        XCTAssertEqual(bus.subscriberCount(for: TestPong.self), 0)
    }

    // An unsubscribed handler no longer receives events.
    func testUnsubscribeStopsDelivery() {
        let bus = EventBus()
        var total = 0
        let sub = bus.subscribe(TestPing.self) { total += $0.value }
        bus.publish(TestPing(value: 1))
        bus.unsubscribe(sub)
        bus.publish(TestPing(value: 5))
        XCTAssertEqual(total, 1)
        XCTAssertEqual(bus.subscriberCount(for: TestPing.self), 0)
    }

    // A handler that unsubscribes itself during dispatch is not called again.
    func testUnsubscribeDuringDispatchTakesEffectAfterwards() {
        let bus = EventBus()
        var calls = 0
        var selfSub: Subscription?
        selfSub = bus.subscribe(TestPing.self) { _ in
            calls += 1
            if let s = selfSub { bus.unsubscribe(s) }
        }
        bus.publish(TestPing(value: 1))
        bus.publish(TestPing(value: 1))
        XCTAssertEqual(calls, 1)
    }

    // enqueue defers delivery until flush, which then delivers in FIFO order.
    func testEnqueueDefersUntilFlush() {
        let bus = EventBus()
        var received: [Int] = []
        bus.subscribe(TestPing.self) { received.append($0.value) }
        bus.enqueue(TestPing(value: 1))
        bus.enqueue(TestPing(value: 2))
        XCTAssertEqual(bus.queuedCount, 2)
        XCTAssertTrue(received.isEmpty)
        bus.flush()
        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(bus.queuedCount, 0)
    }

    // Events enqueued while a flush is running are delivered within the same flush.
    func testEventsEnqueuedDuringFlushAreDeliveredInSameFlush() {
        let bus = EventBus()
        var log: [String] = []
        bus.subscribe(TestPing.self) { ping in
            log.append("ping\(ping.value)")
            bus.enqueue(TestPong(text: "from \(ping.value)"))
        }
        bus.subscribe(TestPong.self) { log.append("pong:\($0.text)") }
        bus.enqueue(TestPing(value: 1))
        bus.flush()
        XCTAssertEqual(log, ["ping1", "pong:from 1"])
    }

    // publish does not deliver events that are only queued.
    func testPublishDoesNotDeliverQueuedEvents() {
        let bus = EventBus()
        var count = 0
        bus.subscribe(TestPing.self) { _ in count += 1 }
        bus.enqueue(TestPing(value: 1))
        bus.publish(TestPing(value: 2))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bus.queuedCount, 1)
    }

    // A handler that keeps re-enqueuing cannot stall a flush: the overflow waits for the next one.
    func testFlushIsCappedAndCarriesOverflow() {
        let bus = EventBus()
        bus.maxEventsPerFlush = 10
        var delivered = 0
        bus.subscribe(TestPing.self) { [unowned bus] _ in
            delivered += 1
            bus.enqueue(TestPing(value: 0))
        }
        bus.enqueue(TestPing(value: 0))
        bus.flush()
        XCTAssertEqual(delivered, 10)
        XCTAssertEqual(bus.queuedCount, 1)
        bus.flush()
        XCTAssertEqual(delivered, 20)
    }

    // Calling flush from inside a handler does not deliver events twice.
    func testNestedFlushIsIgnored() {
        let bus = EventBus()
        var delivered = 0
        bus.subscribe(TestPing.self) { [unowned bus] _ in
            delivered += 1
            bus.flush()
        }
        bus.enqueue(TestPing(value: 1))
        bus.enqueue(TestPing(value: 2))
        bus.flush()
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(bus.queuedCount, 0)
    }
}

final class ThreadSafeQueueTests: XCTestCase {
    // Items come back out in the order they were pushed, and drain empties the queue.
    func testDrainReturnsItemsInOrderAndEmpties() {
        let queue = ThreadSafeQueue<Int>()
        queue.push(1)
        queue.push(2)
        queue.push(3)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.drain(), [1, 2, 3])
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.drain(), [])
    }

    // Closures posted to a dispatcher run only when it is drained, in the order posted.
    func testMainThreadDispatcherRunsOnDrain() {
        let dispatcher = MainThreadDispatcher()
        var order: [Int] = []
        dispatcher.post { order.append(1) }
        dispatcher.post { order.append(2) }
        XCTAssertTrue(order.isEmpty)
        dispatcher.drain()
        XCTAssertEqual(order, [1, 2])
    }
}

final class LogTests: XCTestCase {
    // Records below the minimum level are dropped and their message is never built.
    func testRecordsBelowMinimumLevelAreFilteredLazily() {
        let log = Log(minimumLevel: .info)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 8)
        log.addSink(ring)
        var built = false
        log.log(
            .debug, "Test",
            { () -> String in
                built = true
                return "hidden"
            }())
        XCTAssertFalse(built)
        XCTAssertTrue(ring.records.isEmpty)
    }

    // Records at or above the minimum level reach the sink with their level, category and message.
    func testRecordsReachSinkWithFields() {
        let log = Log(minimumLevel: .info)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 8)
        log.addSink(ring)
        log.log(.warning, "Asset", "missing texture")
        let record = ring.records.last
        XCTAssertEqual(record?.level, .warning)
        XCTAssertEqual(record?.category, "Asset")
        XCTAssertEqual(record?.message, "missing texture")
    }

    // Metadata passed with a message is kept on the record.
    func testMetadataIsPreserved() {
        let log = Log(minimumLevel: .trace)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 8)
        log.addSink(ring)
        log.log(.error, "Asset", "failed", metadata: ["path": "a.png"])
        XCTAssertEqual(ring.records.last?.metadata["path"], "a.png")
    }

    // The ring buffer keeps only the newest records, returned in chronological order.
    func testRingBufferKeepsNewestRecordsInOrder() {
        let log = Log(minimumLevel: .info)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 3)
        log.addSink(ring)
        for i in 0..<5 { log.log(.info, "Test", "m\(i)") }
        XCTAssertEqual(ring.records.map(\.message), ["m2", "m3", "m4"])
    }

    // clear empties the ring buffer.
    func testClearEmptiesRingBuffer() {
        let log = Log(minimumLevel: .info)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 3)
        log.addSink(ring)
        log.log(.info, "Test", "one")
        ring.clear()
        XCTAssertTrue(ring.records.isEmpty)
    }

    // A removed sink no longer receives records.
    func testRemovedSinkReceivesNothing() {
        let log = Log(minimumLevel: .info)
        log.removeAllSinks()
        let ring = RingBufferLogSink(capacity: 3)
        log.addSink(ring)
        log.removeSink(ring)
        log.log(.info, "Test", "dropped")
        XCTAssertTrue(ring.records.isEmpty)
    }

    // Levels are ordered from trace to fault, and each has a fixed upper-case label.
    func testLevelOrderingAndLabels() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.fault)
        XCTAssertEqual(LogLevel.warning.label, "WARN")
        XCTAssertEqual(LogLevel.error.label, "ERROR")
    }
}
