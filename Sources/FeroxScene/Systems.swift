import Foundation
import FeroxCore

/// Frame phases in execution order. See Docs/05-Engine-Lifecycle.md.
public enum SystemPhase: Int, Comparable, CaseIterable, Sendable, Codable {
    /// After input polling, before gameplay (input mapping, network receive).
    case earlyUpdate
    /// Fixed-rate simulation (physics, deterministic gameplay); may run 0…N times a frame.
    case fixedUpdate
    /// Variable-rate gameplay.
    case update
    /// After gameplay: animation, camera follow, transform propagation.
    case lateUpdate
    /// Just before rendering: render-data extraction.
    case preRender

    public static func < (a: SystemPhase, b: SystemPhase) -> Bool { a.rawValue < b.rawValue }
}

/// Context passed to systems each invocation.
public struct SystemContext {
    public var time: FrameTime
    /// Delta to use for this invocation (`fixedDelta` in `.fixedUpdate`, `delta` otherwise).
    public var dt: Float
    public var events: EventBus
    public var isEditMode: Bool
    public init(time: FrameTime, dt: Float, events: EventBus, isEditMode: Bool = false) {
        self.time = time
        self.dt = dt
        self.events = events
        self.isEditMode = isEditMode
    }
}

/// A unit of behaviour operating on a `World`.
public protocol System: AnyObject {
    var phase: SystemPhase { get }
    /// Ordering within a phase (lower runs first).
    var order: Int { get }
    /// Systems that also run while the editor is not in play mode.
    var runsInEditMode: Bool { get }
    var isEnabled: Bool { get }
    func update(world: World, context: SystemContext)
    /// Called once when added to a scheduler.
    func attach(world: World)
    /// Called once when removed.
    func detach(world: World)
}

extension System {
    public var order: Int { 0 }
    public var runsInEditMode: Bool { false }
    public var isEnabled: Bool { true }
    public func attach(world: World) {}
    public func detach(world: World) {}
}

/// Closure-backed system for quick gameplay logic.
public final class ClosureSystem: System {
    public let phase: SystemPhase
    public let order: Int
    public let runsInEditMode: Bool
    public var isEnabled = true
    public let name: String
    private let body: (World, SystemContext) -> Void
    public init(
        _ name: String, phase: SystemPhase = .update, order: Int = 0, runsInEditMode: Bool = false,
        _ body: @escaping (World, SystemContext) -> Void
    ) {
        self.name = name
        self.phase = phase
        self.order = order
        self.runsInEditMode = runsInEditMode
        self.body = body
    }
    public func update(world: World, context: SystemContext) { body(world, context) }
}

/// Orders and runs systems by phase. Each system invocation is wrapped in a profiler scope.
public final class SystemScheduler {
    private var systems: [any System] = []
    private var sorted = true
    public private(set) weak var world: World?

    public init(world: World) { self.world = world }

    public func add(_ s: any System) {
        systems.append(s)
        sorted = false
        if let world { s.attach(world: world) }
    }

    public func remove(_ s: any System) {
        systems.removeAll { $0 === s }
        if let world { s.detach(world: world) }
    }

    public func system<S: System>(_ type: S.Type) -> S? { systems.first { $0 is S } as? S }

    public var all: [any System] { systems }

    public func run(_ phase: SystemPhase, context: SystemContext) {
        guard let world else { return }
        if !sorted {
            // Stable sort: phase, then order, then insertion.
            systems = systems.enumerated().sorted {
                ($0.element.phase, $0.element.order, $0.offset) < ($1.element.phase, $1.element.order, $1.offset)
            }.map(\.element)
            sorted = true
        }
        for s in systems where s.phase == phase && s.isEnabled && (!context.isEditMode || s.runsInEditMode) {
            Profiler.shared.scope(String(describing: type(of: s))) {
                s.update(world: world, context: context)
            }
            world.flushDeferred()
        }
    }
}
