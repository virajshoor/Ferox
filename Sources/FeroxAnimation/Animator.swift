import FeroxCore
import FeroxScene
import Foundation

/// Typed animator parameter.
public enum AnimatorParameter: Codable, Hashable, Sendable {
    case float(Float)
    case bool(Bool)
    /// Consumed by the first transition that tests it.
    case trigger(Bool)
}

/// Transition condition evaluated against animator parameters.
public enum TransitionCondition: Codable, Hashable, Sendable {
    case greater(String, Float)
    case less(String, Float)
    case isTrue(String)
    case isFalse(String)
    case trigger(String)
}

/// A state plays a clip or a 1D blend tree.
public struct AnimatorState: Codable, Hashable, Sendable {
    public struct BlendPoint: Codable, Hashable, Sendable {
        public var clip: AssetID
        public var threshold: Float
        public init(clip: AssetID, threshold: Float) {
            self.clip = clip
            self.threshold = threshold
        }
    }
    public var name: String
    public var clip: AssetID?
    /// 1D blend tree (e.g. idle/walk/run by speed) driven by `blendParameter`.
    public var blendTree: [BlendPoint]
    public var blendParameter: String?
    public var speed: Float = 1
    public init(name: String, clip: AssetID?, speed: Float = 1) {
        self.name = name
        self.clip = clip
        blendTree = []
        self.speed = speed
    }
    public init(name: String, blendTree: [BlendPoint], parameter: String) {
        self.name = name
        clip = nil
        self.blendTree = blendTree.sorted { $0.threshold < $1.threshold }
        blendParameter = parameter
    }
}

public struct AnimatorTransition: Codable, Hashable, Sendable {
    /// Source state name, or nil for "any state".
    public var from: String?
    public var to: String
    public var conditions: [TransitionCondition]
    /// Cross-fade duration in seconds.
    public var duration: Float
    /// Normalised time [0, 1] of the source state after which the transition may fire; nil = any time.
    public var exitTime: Float?
    public init(from: String?, to: String, conditions: [TransitionCondition], duration: Float = 0.2, exitTime: Float? = nil) {
        self.from = from
        self.to = to
        self.conditions = conditions
        self.duration = duration
        self.exitTime = exitTime
    }
}

/// State machine definition (Unity "Animator Controller").
public struct AnimatorController: Codable, Hashable, Sendable {
    public var states: [AnimatorState]
    public var transitions: [AnimatorTransition]
    public var defaultState: String
    public var defaultParameters: [String: AnimatorParameter]
    public init(states: [AnimatorState], transitions: [AnimatorTransition], defaultState: String,
                parameters: [String: AnimatorParameter] = [:]) {
        self.states = states
        self.transitions = transitions
        self.defaultState = defaultState
        defaultParameters = parameters
    }
    public func state(named n: String) -> AnimatorState? { states.first { $0.name == n } }
}

/// Plays an `AnimatorController` on an entity. For skinned characters the animator writes
/// to the joint entities listed in `SkeletonBinding`; otherwise channels target child
/// entities by name path.
public struct Animator: SerializableComponent, Hashable, Sendable {
    public var controller: AnimatorController
    public var parameters: [String: AnimatorParameter]
    public var speed: Float = 1
    public var isPlaying = true
    public internal(set) var currentState: String
    public internal(set) var stateTime: Float = 0
    public internal(set) var previousState: String?
    public internal(set) var previousStateTime: Float = 0
    public internal(set) var fadeElapsed: Float = 0
    public internal(set) var fadeDuration: Float = 0

    public init(controller: AnimatorController) {
        self.controller = controller
        parameters = controller.defaultParameters
        currentState = controller.defaultState
    }

    /// Single-clip convenience (looping playback with no transitions).
    public init(clip: AssetID) {
        self.init(controller: AnimatorController(states: [AnimatorState(name: "Default", clip: clip)], transitions: [], defaultState: "Default"))
    }

    public mutating func set(_ name: String, _ value: Float) { parameters[name] = .float(value) }
    public mutating func set(_ name: String, _ value: Bool) { parameters[name] = .bool(value) }
    public mutating func trigger(_ name: String) { parameters[name] = .trigger(true) }

    /// Immediately cross-fades to a state.
    public mutating func crossFade(to state: String, duration: Float = 0.2) {
        guard state != currentState, controller.state(named: state) != nil else { return }
        previousState = currentState
        previousStateTime = stateTime
        currentState = state
        stateTime = 0
        fadeElapsed = 0
        fadeDuration = max(duration, 0)
    }

    func check(_ c: TransitionCondition) -> Bool {
        switch c {
        case let .greater(n, v): if case .float(let f)? = parameters[n] { return f > v } else { return false }
        case let .less(n, v): if case .float(let f)? = parameters[n] { return f < v } else { return false }
        case .isTrue(let n): if case .bool(let b)? = parameters[n] { return b } else { return false }
        case .isFalse(let n): if case .bool(let b)? = parameters[n] { return !b } else { return true }
        case .trigger(let n): if case .trigger(let b)? = parameters[n] { return b } else { return false }
        }
    }

    /// Advances time and evaluates transitions. `clipDuration` resolves state durations.
    mutating func advance(dt: Float, clipDuration: (AnimatorState) -> Float) {
        guard isPlaying else { return }
        let step = dt * speed
        if let st = controller.state(named: currentState) { stateTime += step * st.speed }
        if previousState != nil {
            previousStateTime += step
            fadeElapsed += step
            if fadeElapsed >= fadeDuration { previousState = nil }
        }
        guard let st = controller.state(named: currentState) else { return }
        let dur = max(clipDuration(st), 1e-4)
        let normalized = stateTime / dur
        for t in controller.transitions where (t.from == nil || t.from == currentState) && t.to != currentState {
            if let exit = t.exitTime, normalized.truncatingRemainder(dividingBy: 1) < exit && normalized < 1 { continue }
            guard t.conditions.allSatisfy(check) else { continue }
            for c in t.conditions { if case .trigger(let n) = c { parameters[n] = .trigger(false) } }
            crossFade(to: t.to, duration: t.duration)
            break
        }
    }

    /// Weight of the current state in the cross-fade (1 when not fading).
    public var currentWeight: Float {
        guard previousState != nil, fadeDuration > 0 else { return 1 }
        return (fadeElapsed / fadeDuration).saturated
    }
}

/// Maps skeleton joints to entities (created when a skinned model is instantiated).
public struct SkeletonBinding: Component, Hashable, Sendable {
    public var skeleton: AssetID
    public var joints: [Entity]
    public init(skeleton: AssetID, joints: [Entity]) {
        self.skeleton = skeleton
        self.joints = joints
    }
}

/// Fired through the event bus when an animation crosses an `AnimationEvent`.
public struct AnimationEventFired: Event, Sendable {
    public var entity: Entity
    public var clip: String
    public var event: AnimationEvent
}
