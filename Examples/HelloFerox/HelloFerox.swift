import Ferox

/// The smallest complete Ferox program: a lit, spinning cube on a ground plane, a
/// procedural sky and a frame-rate label.
///
/// Run with `swift run HelloFerox` (macOS window) or
/// `swift run HelloFerox --headless --frames 120` (any platform, no rendering).
final class HelloGame: Game {
    private var cube = Entity.null
    private let label = UILabel("Hello, Ferox")

    func setup(engine: Engine) throws {
        let world = engine.world

        // Assets can come from files (EngineConfiguration.assetRoot) or be registered in
        // code, as here. Ids are stable strings so scenes can refer to them.
        let cubeMesh = AssetID("hello.mesh.cube")
        let planeMesh = AssetID("hello.mesh.plane")
        _ = engine.assets.registerMesh(.cube(size: 1), id: cubeMesh)
        _ = engine.assets.registerMesh(.plane(size: 20), id: planeMesh)

        var copper = MaterialData(id: AssetID("hello.material.copper"), name: "Copper")
        copper.baseColor = Color(0.95, 0.64, 0.54)
        copper.metallic = 1
        copper.roughness = 0.3
        var floor = MaterialData(id: AssetID("hello.material.floor"), name: "Floor")
        floor.baseColor = Color(0.5, 0.5, 0.52)
        floor.roughness = 0.8
        _ = engine.assets.registerMaterial(copper)
        _ = engine.assets.registerMaterial(floor)

        cube = world.createEntity(named: "Cube", transform: Transform(position: Vec3(0, 0.75, 0)))
        world.add(MeshRenderer(mesh: cubeMesh, materials: [copper.id]), to: cube)

        let ground = world.createEntity(named: "Ground")
        world.add(MeshRenderer(mesh: planeMesh, materials: [floor.id]), to: ground)

        // Directional lights shine along their entity's forward (−Z) axis.
        let sun = world.createEntity(
            named: "Sun", transform: Transform(rotation: .lookRotation(forward: Vec3(-0.4, -1, -0.3).normalized)))
        world.add(Light.directional(intensity: 4, shadows: true), to: sun)

        let camera = world.createEntity(
            named: "Camera",
            transform: Transform(position: Vec3(0, 2, 4.5), rotation: .lookRotation(forward: Vec3(0, -0.3, -1).normalized)))
        world.add(Camera.perspective(fov: 55), to: camera)

        let environment = world.createEntity(named: "Environment")
        world.add(Environment(), to: environment)

        label.anchors = .point(Vec2(0, 0), size: Vec2(360, 28), pivot: Vec2(0, 0), offset: Vec2(16, 16))
        engine.ui.add(label)
    }

    func update(engine: Engine, time: FrameTime) {
        let angle = Float(time.elapsed)
        engine.world.modify(Transform.self, cube) {
            $0.rotation = Quat(angle: angle, axis: Vec3(0, 1, 0)) * Quat(angle: angle * 0.5, axis: Vec3(1, 0, 0))
        }
        let fps = engine.frameStatistics.averageFPS
        label.text = fps > 0 ? "Hello, Ferox — \(Int(fps.rounded())) FPS" : "Hello, Ferox"
    }
}

@main
enum HelloFeroxMain {
    @MainActor static func main() {
        GameLauncher.main(HelloGame(), configuration: EngineConfiguration(title: "Hello Ferox"))
    }
}
