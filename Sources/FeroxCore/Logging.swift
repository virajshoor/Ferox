import Foundation

#if canImport(os)
import os
#endif

/// Severity of a log message.
public enum LogLevel: Int, Comparable, Codable, Sendable, CaseIterable {
    case trace, debug, info, warning, error, fault

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}

/// A structured log record. Records are value types so sinks can retain them cheaply.
public struct LogRecord: Sendable, Identifiable, Hashable {
    public let id: UInt64
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let file: String
    public let line: Int
    /// Optional key/value metadata (e.g. asset path, entity id).
    public let metadata: [String: String]
}

/// Destination for log records. Sinks are called synchronously on the logging thread
/// while the logger's lock is *not* held, so they must be internally thread-safe.
public protocol LogSink: AnyObject, Sendable {
    func receive(_ record: LogRecord)
}

/// Process-wide structured logger.
///
/// Logging is cheap when filtered: the message autoclosure is evaluated only if the
/// record passes the level threshold. Records are fanned out to registered sinks, which
/// by default include stderr (and the unified logging system on Apple platforms).
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var sinks: [any LogSink] = []
    private var nextID: UInt64 = 0
    private var _minimumLevel: LogLevel

    public var minimumLevel: LogLevel {
        get { lock.locked { _minimumLevel } }
        set { lock.locked { _minimumLevel = newValue } }
    }

    public init(minimumLevel: LogLevel? = nil) {
        #if FEROX_DEBUG
        _minimumLevel = minimumLevel ?? .debug
        #else
        _minimumLevel = minimumLevel ?? .info
        #endif
        sinks = [ConsoleLogSink()]
    }

    public func addSink(_ sink: any LogSink) { lock.locked { sinks.append(sink) } }
    public func removeSink(_ sink: any LogSink) { lock.locked { sinks.removeAll { $0 === sink } } }
    public func removeAllSinks() { lock.locked { sinks.removeAll() } }

    public func log(
        _ level: LogLevel, _ category: String, _ message: @autoclosure () -> String,
        metadata: [String: String] = [:], file: String = #fileID, line: Int = #line
    ) {
        let (accept, targets, id): (Bool, [any LogSink], UInt64) = lock.locked {
            guard level >= _minimumLevel else { return (false, [], 0) }
            nextID &+= 1
            return (true, sinks, nextID)
        }
        guard accept else { return }
        let record = LogRecord(
            id: id, timestamp: Date(), level: level, category: category, message: message(), file: file, line: line,
            metadata: metadata)
        for sink in targets { sink.receive(record) }
    }

    // Convenience entry points.
    public static func trace(_ category: String, _ m: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.log(.trace, category, m(), file: file, line: line)
    }
    public static func debug(_ category: String, _ m: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.log(.debug, category, m(), file: file, line: line)
    }
    public static func info(_ category: String, _ m: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.log(.info, category, m(), file: file, line: line)
    }
    public static func warning(_ category: String, _ m: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.log(.warning, category, m(), file: file, line: line)
    }
    public static func error(_ category: String, _ m: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.log(.error, category, m(), file: file, line: line)
    }
}

/// Writes records to standard error and, on Apple platforms, to the unified logging system.
public final class ConsoleLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(os)
    private var loggers: [String: os.Logger] = [:]
    #endif
    public var useUnifiedLogging: Bool

    public init(useUnifiedLogging: Bool = false) { self.useUnifiedLogging = useUnifiedLogging }

    public func receive(_ r: LogRecord) {
        let line = "[\(r.level.label)] [\(r.category)] \(r.message)\n"
        lock.locked {
            FileHandle.standardError.write(Data(line.utf8))
            #if canImport(os)
            if useUnifiedLogging {
                let logger = loggers[r.category] ?? os.Logger(subsystem: "dev.ferox.engine", category: r.category)
                loggers[r.category] = logger
                switch r.level {
                case .trace, .debug: logger.debug("\(r.message, privacy: .public)")
                case .info: logger.info("\(r.message, privacy: .public)")
                case .warning: logger.warning("\(r.message, privacy: .public)")
                case .error: logger.error("\(r.message, privacy: .public)")
                case .fault: logger.fault("\(r.message, privacy: .public)")
                }
            }
            #endif
        }
    }
}

/// Keeps the most recent records in memory; used by the editor console and tests.
public final class RingBufferLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogRecord] = []
    private var head = 0
    public let capacity: Int
    /// Called (on the logging thread) after each record is stored.
    public var onRecord: (@Sendable (LogRecord) -> Void)?

    public init(capacity: Int = 4096) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public func receive(_ record: LogRecord) {
        let callback: (@Sendable (LogRecord) -> Void)? = lock.locked {
            if storage.count < capacity {
                storage.append(record)
            } else {
                storage[head] = record
                head = (head + 1) % capacity
            }
            return onRecord
        }
        callback?(record)
    }

    /// Records in chronological order.
    public var records: [LogRecord] {
        lock.locked { storage.count < capacity ? storage : Array(storage[head...] + storage[..<head]) }
    }

    public func clear() { lock.locked { storage.removeAll(keepingCapacity: true); head = 0 } }
}

extension NSLock {
    /// Runs `body` while holding the lock.
    @inlinable public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
