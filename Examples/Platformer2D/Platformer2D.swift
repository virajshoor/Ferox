import Ferox
import Foundation

/// A small side-scrolling platformer: 2D physics, action-mapped input, trigger pickups,
/// a following orthographic camera and a score HUD. Every visual is a `ShapeRenderer`,
/// so the example needs no image files.
///
/// Controls: A/D or ←/→ (or the left stick) to move, Space (or the south button) to jump.
final class PlatformerGame: Game {
    private var player = Entity.null
    private var camera = Entity.null
    private var coins: Set<Entity> = []
    private var score = 0
    private var jumpQueued = false
    private var subscription: Subscription?
    private let hud = UILabel("Coins: 0")

    private let playerSize = Vec2(0.8, 1.2)
    private let moveSpeed: Float = 7
    private let jumpSpeed: Float = 11

    func setup(engine: Engine) throws {
        let world = engine.world
        engine.physics2D?.physics.gravity = Vec2(0, -25)

        // Level: (centre x, centre y, width, height) of each platform.
        let platforms: [(Float, Float, Float, Float)] = [
            (0, -1, 40, 2), (6, 2, 4, 0.5), (12, 4, 4, 0.5), (18, 2.5, 3, 0.5), (24, 5, 5, 0.5), (-8, 2, 3, 0.5),
        ]
        for (i, p) in platforms.enumerated() {
            let e = world.createEntity(named: "Platform \(i)", transform: Transform(position: Vec3(p.0, p.1, 0)))
            world.add(RigidBody2D(type: .static), to: e)
            world.add(Collider2D.box(Vec2(p.2, p.3)), to: e)
            var shape = ShapeRenderer(.rectangle(size: Vec2(p.2, p.3), cornerRadius: 0.08), color: Color(0.25, 0.3, 0.38))
            shape.strokeWidth = 0.05
            shape.strokeColor = Color(0.45, 0.55, 0.7)
            world.add(shape, to: e)
        }

        player = world.createEntity(named: "Player", transform: Transform(position: Vec3(0, 1, 0)))
        var body = RigidBody2D(type: .dynamic)
        body.fixedRotation = true
        body.allowSleep = false // velocity is driven every step
        world.add(body, to: player)
        world.add(Collider2D.box(playerSize, material: PhysicsMaterial(friction: 0, restitution: 0)), to: player)
        var look = ShapeRenderer(.rectangle(size: playerSize, cornerRadius: 0.15), color: Color(0.95, 0.55, 0.2))
        look.orderInLayer = 10
        world.add(look, to: player)

        for (i, p) in [Vec2(6, 3.2), Vec2(12, 5.2), Vec2(18, 3.7), Vec2(24, 6.2), Vec2(-8, 3.2)].enumerated() {
            let coin = world.createEntity(named: "Coin \(i)", transform: Transform(position: Vec3(p.x, p.y, 0)))
            world.add(RigidBody2D(type: .kinematic), to: coin)
            world.add(Collider2D.circle(0.3, isTrigger: true), to: coin)
            world.add(ShapeRenderer(.circle(radius: 0.3, segments: 24), color: Color(1, 0.85, 0.2)), to: coin)
            coins.insert(coin)
        }

        camera = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 2, 10)))
        var cam = Camera.orthographic(size: 7)
        cam.clearColor = Color(0.07, 0.08, 0.12)
        world.add(cam, to: camera)

        // Pick-ups: physics publishes trigger contacts as events after each fixed step.
        subscription = engine.events.subscribe(CollisionEvent2D.self) { [weak self, weak engine] event in
            guard let self, let engine, event.isTrigger, event.phase == .began, event.involves(self.player) else { return }
            let other = event.other(than: self.player)
            guard self.coins.remove(other) != nil else { return }
            engine.world.deferStructural { engine.world.destroy(other) }
            self.score += 1
            self.hud.text = "Coins: \(self.score)" + (self.coins.isEmpty ? " — all collected!" : "")
        }

        hud.anchors = .point(Vec2(0, 0), size: Vec2(320, 28), pivot: Vec2(0, 0), offset: Vec2(16, 16))
        engine.ui.add(hud)
    }

    func update(engine: Engine, time: FrameTime) {
        // Sample presses every rendered frame so a tap between fixed steps is not lost.
        if engine.input.wasPressed("Jump") { jumpQueued = true }
    }

    func fixedUpdate(engine: Engine, dt: Float) {
        guard let system = engine.physics2D, let id = system.body(for: player),
              let body = system.physics.body(id) else { return }
        let physics = system.physics
        let move = engine.input.vector("Move").x
        var velocity = body.linearVelocity
        velocity.x = move * moveSpeed
        if jumpQueued {
            jumpQueued = false
            if isGrounded(physics, at: body.position) { velocity.y = jumpSpeed }
        }
        physics.setLinearVelocity(id, velocity)

        // Fell off the level: respawn.
        if body.position.y < -20 {
            physics.setTransform(id, position: Vec2(0, 1), angle: 0, resetInterpolation: true)
            physics.setLinearVelocity(id, .zero)
        }
    }

    func lateUpdate(engine: Engine, time: FrameTime) {
        // Critically damped follow, frame-rate independent.
        guard let target = engine.world.get(Transform.self, player)?.position else { return }
        let k = 1 - exp(-6 * Float(time.delta))
        engine.world.modify(Transform.self, camera) { t in
            t.position.x += (target.x - t.position.x) * k
            t.position.y += (target.y + 1.5 - t.position.y) * k
        }
    }

    func shutdown(engine: Engine) {
        if let subscription { engine.events.unsubscribe(subscription) }
    }

    /// Short ray just below the feet; starting outside the player's own collider means it
    /// cannot hit the player.
    private func isGrounded(_ physics: PhysicsWorld2D, at position: Vec2) -> Bool {
        let feet = position.y - playerSize.y * 0.5
        for dx in [-playerSize.x * 0.4, 0, playerSize.x * 0.4] {
            let from = Vec2(position.x + dx, feet - 0.01)
            if physics.raycast(from: from, to: from - Vec2(0, 0.12)) != nil { return true }
        }
        return false
    }
}

@main
enum Platformer2DMain {
    @MainActor static func main() {
        var config = EngineConfiguration(title: "Platformer 2D")
        config.physics3D = false
        // 2D art is authored in display colours: no tone mapping.
        config.graphics.post.toneMapper = .none
        GameLauncher.main(PlatformerGame(), configuration: config)
    }
}
