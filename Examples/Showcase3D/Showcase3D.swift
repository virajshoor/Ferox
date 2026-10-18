import Ferox

/// A tour of the 3D renderer and physics:
/// - a 7×7 grid of PBR spheres sweeping metallic (rows) and roughness (columns);
/// - rigid-body crates dropped onto the floor every second (recycled after 40);
/// - coloured point lights orbiting the scene, a shadow-casting sun, procedural sky and
///   a reflection probe for local reflections;
/// - a settings panel switching quality presets, anti-aliasing and ray tracing live.
///
/// Controls: W/A/S/D or the left stick orbit and zoom the camera.
final class ShowcaseGame: Game {
    private var camera = Entity.null
    private var lights: [Entity] = []
    private var crates: [Entity] = []
    private var spawnTimer: Float = 0
    private var orbitYaw: Float = 0.6
    private var orbitDistance: Float = 14
    private let crateMesh = AssetID("showcase.mesh.crate")
    private let crateMaterial = AssetID("showcase.material.crate")
    private let status = UILabel("")
    private var random = PCG32(seed: 7)

    func setup(engine: Engine) throws {
        let world = engine.world
        let assets = engine.assets
        let sphereMesh = AssetID("showcase.mesh.sphere")
        let floorMesh = AssetID("showcase.mesh.floor")
        _ = assets.registerMesh(.sphere(radius: 0.4, segments: 48, rings: 24), id: sphereMesh)
        _ = assets.registerMesh(.plane(size: 40, subdivisions: 4), id: floorMesh)
        _ = assets.registerMesh(.cube(size: 0.6), id: crateMesh)

        // Material sweep.
        for row in 0..<7 {
            for column in 0..<7 {
                var m = MaterialData(id: AssetID("showcase.material.\(row).\(column)"), name: "Sweep \(row),\(column)")
                m.baseColor = Color(0.9, 0.2, 0.15)
                m.metallic = Float(row) / 6
                m.roughness = max(Float(column) / 6, 0.04)
                _ = assets.registerMaterial(m)
                let e = world.createEntity(
                    named: "Sphere \(row),\(column)",
                    transform: Transform(position: Vec3(Float(column - 3) * 1.1, 0.6 + Float(row) * 1.1, -4)))
                var r = MeshRenderer(mesh: sphereMesh, materials: [m.id])
                r.isStatic = true
                world.add(r, to: e)
            }
        }

        var floorMaterial = MaterialData(id: AssetID("showcase.material.floor"), name: "Floor")
        floorMaterial.baseColor = Color(0.35, 0.36, 0.38)
        floorMaterial.roughness = 0.35
        _ = assets.registerMaterial(floorMaterial)
        var crate = MaterialData(id: crateMaterial, name: "Crate")
        crate.baseColor = Color(0.75, 0.55, 0.3)
        crate.roughness = 0.7
        _ = assets.registerMaterial(crate)

        let floor = world.createEntity(named: "Floor")
        var floorRenderer = MeshRenderer(mesh: floorMesh, materials: [floorMaterial.id])
        floorRenderer.isStatic = true
        world.add(floorRenderer, to: floor)
        world.add(RigidBody3D(type: .static), to: floor)
        world.add(Collider3D.box(Vec3(40, 0.2, 40)), to: floor)
        // The collider box is centred on the entity; sink it so its top is at y = 0.
        world.modify(Collider3D.self, floor) { $0.shapes[0].offset = Vec3(0, -0.1, 0) }

        let sun = world.createEntity(
            named: "Sun", transform: Transform(rotation: .lookRotation(forward: Vec3(-0.5, -0.8, -0.35).normalized)))
        world.add(Light.directional(Color(1, 0.96, 0.9), intensity: 5, shadows: true), to: sun)

        let colours = [Color(1, 0.3, 0.2), Color(0.2, 0.6, 1), Color(0.3, 1, 0.4)]
        for (i, c) in colours.enumerated() {
            let e = world.createEntity(named: "Point Light \(i)")
            world.add(Light(type: .point, color: c, intensity: 60, range: 8), to: e)
            lights.append(e)
        }

        let probe = world.createEntity(named: "Reflection Probe", transform: Transform(position: Vec3(0, 3, 0)))
        var p = ReflectionProbe()
        p.extents = Vec3(20, 8, 20)
        world.add(p, to: probe)

        let environment = world.createEntity(named: "Environment")
        var env = Environment()
        env.fogDensity = 0.004
        world.add(env, to: environment)

        camera = world.createEntity(named: "Camera")
        world.add(Camera.perspective(fov: 50, near: 0.1, far: 300), to: camera)

        buildSettingsPanel(engine)
    }

    func update(engine: Engine, time: FrameTime) {
        let dt = Float(time.delta)
        let input = engine.input.vector("Move")
        orbitYaw += input.x * dt * 1.2 + dt * 0.1
        orbitDistance = min(max(orbitDistance - input.y * dt * 8, 6), 30)

        // Lights circle the sphere grid at different speeds and heights.
        let t = Float(time.elapsed)
        for (i, e) in lights.enumerated() {
            let a = t * (0.5 + Float(i) * 0.2) + Float(i) * 2.1
            engine.world.modify(Transform.self, e) { $0.position = Vec3(cos(a) * 5, 1.5 + Float(i), sin(a) * 3 - 2) }
        }

        spawnTimer += dt
        if spawnTimer >= 1 {
            spawnTimer = 0
            spawnCrate(engine)
        }
        let g = engine.graphics
        status.text = "\(g.antiAliasing.mode.rawValue.uppercased()) · ray tracing \(g.rayTracing.enabled ? "on" : "off")"
            + " · \(Int(engine.frameStatistics.averageFPS.rounded())) FPS"
    }

    func lateUpdate(engine: Engine, time: FrameTime) {
        let target = Vec3(0, 2.5, -2)
        let eye = target + Vec3(sin(orbitYaw) * orbitDistance, orbitDistance * 0.35, cos(orbitYaw) * orbitDistance)
        engine.world.modify(Transform.self, camera) { t in
            t.position = eye
            t.rotation = .lookRotation(forward: (target - eye).normalized)
        }
    }

    private func spawnCrate(_ engine: Engine) {
        let world = engine.world
        // Recycle the oldest crate to keep the body count bounded.
        if crates.count >= 40 { world.destroy(crates.removeFirst()) }
        let x = random.nextFloat(in: -3...3), z = random.nextFloat(in: 0...4)
        let spin = Quat(angle: random.nextFloat(in: 0...Float.pi), axis: Vec3(0.3, 1, 0.2).normalized)
        let e = world.createEntity(named: "Crate", transform: Transform(position: Vec3(x, 8, z), rotation: spin))
        world.add(MeshRenderer(mesh: crateMesh, materials: [crateMaterial]), to: e)
        world.add(RigidBody3D(type: .dynamic), to: e)
        world.add(Collider3D.box(Vec3(0.6, 0.6, 0.6)), to: e)
        crates.append(e)
    }

    private func buildSettingsPanel(_ engine: Engine) {
        let panel = UIStack(.vertical, spacing: 6, name: "Settings")
        panel.padding = EdgeInsets(all: 12)
        panel.background = Color(0, 0, 0, 0.55)
        panel.cornerRadius = 8
        panel.anchors = .point(Vec2(0, 0), size: Vec2(300, 220), pivot: Vec2(0, 0), offset: Vec2(16, 16))

        panel.add(UILabel("Quality preset"))
        let presets = UIStack(.horizontal, spacing: 4)
        for preset in QualityPreset.allCases {
            presets.add(UIButton(preset.rawValue.capitalized) { [weak engine] in
                guard let engine else { return }
                var g = engine.graphics
                g.apply(preset)
                engine.graphics = g
            })
        }
        panel.add(presets)

        panel.add(UILabel("Anti-aliasing"))
        let modes = AntiAliasingMode.allCases
        panel.add(UIDropdown(options: modes.map { $0.rawValue.uppercased() },
                             selected: modes.firstIndex(of: engine.graphics.antiAliasing.mode) ?? 0) { [weak engine] i in
            engine?.graphics.antiAliasing.mode = modes[i]
        })
        panel.add(UIToggle("Ray tracing (when supported)", isOn: engine.graphics.rayTracing.enabled) { [weak engine] on in
            engine?.graphics.rayTracing.enabled = on
        })
        panel.add(status)
        engine.ui.add(panel)
    }
}

@main
enum Showcase3DMain {
    @MainActor static func main() {
        var config = EngineConfiguration(title: "Ferox Showcase")
        config.physics2D = false
        config.graphics = GraphicsSettings(preset: .high)
        GameLauncher.main(ShowcaseGame(), configuration: config)
    }
}
