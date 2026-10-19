import FeroxCore
/// Tests for the animation subsystem: easing endpoints, curve sampling, tween progression and loop
/// modes, clip timing and event crossing, flipbooks and the CPU particle emitter.
import XCTest

@testable import FeroxAnimation
@testable import FeroxScene

final class AnimationTests: XCTestCase {

    /// Creates an entity with a default Transform.
    private func makeTransformEntity(_ world: World) -> Entity {
        let e = world.createEntity()
        world.add(Transform(), to: e)
        return e
    }

    /// Advances a tween system by one invocation with the given delta.
    private func tick(_ system: TweenSystem, _ world: World, dt: Float, events: EventBus = EventBus()) {
        system.update(world: world, context: SystemContext(time: FrameTime(), dt: dt, events: events))
    }

    /// Every easing function maps 0 to 0 and 1 to 1.
    func testEveryEasingHasFixedEndpoints() {
        for easing in Easing.allCases {
            XCTAssertEqual(easing.apply(0), 0, accuracy: 1e-4, "\(easing) at 0")
            XCTAssertEqual(easing.apply(1), 1, accuracy: 1e-4, "\(easing) at 1")
        }
    }

    /// Selected easings take their documented midpoint values, and inputs outside [0, 1] are clamped.
    func testEasingKnownValuesAndClamping() {
        XCTAssertEqual(Easing.easeInQuad.apply(0.5), 0.25, accuracy: 1e-5)
        XCTAssertEqual(Easing.easeOutQuad.apply(0.5), 0.75, accuracy: 1e-5)
        XCTAssertEqual(Easing.easeInOutQuad.apply(0.25), 0.125, accuracy: 1e-5)
        XCTAssertEqual(Easing.linear.apply(-1), 0, accuracy: 1e-6)
        XCTAssertEqual(Easing.linear.apply(2), 1, accuracy: 1e-6)
    }

    /// Linear curves interpolate and clamp outside the key range; step curves hold the earlier key's value.
    func testCurveInterpolationModes() throws {
        let linear = AnimationCurve<Float>(keys: [.init(0, 0), .init(1, 10)], interpolation: .linear)
        XCTAssertEqual(try XCTUnwrap(linear.sample(0.25)), 2.5, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(linear.sample(-1)), 0, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(linear.sample(2)), 10, accuracy: 1e-5)

        let step = AnimationCurve<Float>(keys: [.init(0, 0), .init(1, 10)], interpolation: .step)
        XCTAssertEqual(try XCTUnwrap(step.sample(0.99)), 0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(step.sample(1)), 10, accuracy: 1e-6)
    }

    /// Keys supplied out of order are sorted on construction, so sampling is unaffected by input order.
    func testCurveSortsKeysOnConstruction() throws {
        let curve = AnimationCurve<Float>(keys: [.init(1, 10), .init(0, 0)], interpolation: .linear)
        XCTAssertEqual(curve.keys.map(\.time), [0, 1])
        XCTAssertEqual(try XCTUnwrap(curve.sample(0.5)), 5, accuracy: 1e-5)
    }

    /// A once-tween moves the transform along its easing, then removes itself and reports completion.
    func testOnceTweenCompletesAndRemovesItself() throws {
        let world = World()
        let e = makeTransformEntity(world)
        world.add(Tween(.position(from: Vec3(0, 0, 0), to: Vec3(10, 0, 0)), duration: 1, easing: .linear), to: e)
        let bus = EventBus()
        var completed: [Entity] = []
        _ = bus.subscribe(TweenCompleted.self) { completed.append($0.entity) }

        let system = TweenSystem()
        tick(system, world, dt: 0.5, events: bus)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, e)).position.x, 5, accuracy: 1e-4)
        XCTAssertTrue(world.has(Tween.self, e))

        tick(system, world, dt: 0.5, events: bus)
        bus.flush()
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, e)).position.x, 10, accuracy: 1e-4)
        XCTAssertFalse(world.has(Tween.self, e))
        XCTAssertEqual(completed, [e])
    }

    /// A tween with a delay leaves its transform at the start value until the delay has elapsed.
    func testTweenDelayHoldsStartValue() throws {
        let world = World()
        let e = world.createEntity()
        world.add(Transform(position: Vec3(2, 0, 0)), to: e)
        world.add(
            Tween(.position(from: Vec3(2, 0, 0), to: Vec3(12, 0, 0)), duration: 1, easing: .linear, delay: 1), to: e)
        tick(TweenSystem(), world, dt: 0.5)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, e)).position.x, 2, accuracy: 1e-4)
    }

    /// A looping tween wraps its progress back to the start and keeps running.
    func testLoopingTweenWrapsProgress() throws {
        let world = World()
        let e = makeTransformEntity(world)
        world.add(
            Tween(.position(from: Vec3(0, 0, 0), to: Vec3(10, 0, 0)), duration: 1, easing: .linear, loop: .loop), to: e)
        tick(TweenSystem(), world, dt: 1.5)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, e)).position.x, 5, accuracy: 1e-4)
        XCTAssertTrue(world.has(Tween.self, e))
    }

    /// A ping-pong tween reflects its progress once it passes the end of the duration.
    func testPingPongTweenReflectsProgress() throws {
        let world = World()
        let e = makeTransformEntity(world)
        world.add(
            Tween(.position(from: Vec3(0, 0, 0), to: Vec3(10, 0, 0)), duration: 1, easing: .linear, loop: .pingPong),
            to: e)
        tick(TweenSystem(), world, dt: 1.25)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, e)).position.x, 7.5, accuracy: 1e-4)
    }

    /// Clip local time wraps when looping and clamps when not.
    func testClipLocalTimeLoopsOrClamps() {
        let looping = AnimationClip(name: "loop", channels: [], duration: 2, loops: true)
        XCTAssertEqual(looping.localTime(2.5), 0.5, accuracy: 1e-5)
        XCTAssertEqual(looping.localTime(-0.5), 1.5, accuracy: 1e-5)

        let once = AnimationClip(name: "once", channels: [], duration: 2, loops: false)
        XCTAssertEqual(once.localTime(5), 2, accuracy: 1e-5)
        XCTAssertEqual(once.localTime(-1), 0, accuracy: 1e-5)
    }

    /// Events are reported once each when playback crosses them, including across a loop boundary.
    func testClipEventsFireWhenCrossedAcrossLoopBoundary() {
        let clip = AnimationClip(
            name: "events", channels: [],
            events: [AnimationEvent(time: 0.5, name: "a"), AnimationEvent(time: 1.5, name: "b")],
            duration: 2, loops: true)
        XCTAssertEqual(clip.events(from: 0, to: 1).map(\.name), ["a"])
        XCTAssertEqual(clip.events(from: 1, to: 2.6).map(\.name).sorted(), ["a", "b"])
        XCTAssertTrue(clip.events(from: 0.6, to: 1.4).isEmpty)
    }

    /// A flipbook samples frame indices with step interpolation over its frame rectangles.
    func testFlipbookSamplesFrameIndexWithStepInterpolation() throws {
        let frames = (0..<4).map { Rect(x: Float($0) * 8, y: 0, width: 8, height: 8) }
        let clip = AnimationClip.flipbook(name: "spin", frames: frames, fps: 4)
        XCTAssertEqual(clip.spriteFrames.count, 4)
        XCTAssertEqual(clip.duration, 1, accuracy: 1e-5)
        let curve = try XCTUnwrap(clip.channels.first?.float)
        XCTAssertEqual(try XCTUnwrap(curve.sample(0.6)), 2, accuracy: 1e-5)
    }

    /// The CPU simulation spawns the requested particles and kills those that outlive their lifetime.
    func testSimulationSpawnsAndKillsAgedParticles() {
        var emitter = ParticleEmitter()
        emitter.lifetime = 5...5
        var state = ParticleState(capacity: 16, seed: 7)
        ParticleSystem.simulate(emitter, &state, spawn: 5, dt: 0.1, emitterMatrix: .identity)
        XCTAssertEqual(state.pool.count, 5)

        ParticleSystem.simulate(emitter, &state, spawn: 0, dt: 6, emitterMatrix: .identity)
        XCTAssertEqual(state.pool.count, 0)
    }

    /// Spawning never exceeds the pool capacity given by maxParticles.
    func testSimulationRespectsPoolCapacity() {
        var emitter = ParticleEmitter()
        emitter.lifetime = 5...5
        var state = ParticleState(capacity: 4, seed: 3)
        ParticleSystem.simulate(emitter, &state, spawn: 10, dt: 0.1, emitterMatrix: .identity)
        XCTAssertEqual(state.pool.count, 4)
    }

    /// A rate-driven emitter spawns rate x elapsed-time particles across several updates.
    func testRateEmitterSpawnsExpectedCount() {
        let world = World()
        let e = makeTransformEntity(world)
        var emitter = ParticleEmitter()
        emitter.rate = 10
        emitter.lifetime = 5...5
        emitter.maxParticles = 100
        world.add(emitter, to: e)

        let system = ParticleSystem()
        for _ in 0..<4 {
            system.update(world: world, context: SystemContext(time: FrameTime(), dt: 0.25, events: EventBus()))
        }
        XCTAssertEqual(try XCTUnwrap(world.get(ParticleState.self, e)).pool.count, 10)
    }

    /// A burst fires once when playback crosses its time and not before.
    func testBurstSpawnsWhenCrossed() throws {
        let world = World()
        let e = makeTransformEntity(world)
        var emitter = ParticleEmitter()
        emitter.rate = 0
        emitter.lifetime = 5...5
        emitter.bursts = [ParticleEmitter.Burst(time: 0.5, count: 7)]
        world.add(emitter, to: e)

        let system = ParticleSystem()
        let context = SystemContext(time: FrameTime(), dt: 0.25, events: EventBus())
        system.update(world: world, context: context)
        XCTAssertEqual(try XCTUnwrap(world.get(ParticleState.self, e)).pool.count, 0)
        system.update(world: world, context: context)
        XCTAssertEqual(try XCTUnwrap(world.get(ParticleState.self, e)).pool.count, 7)
    }
}
