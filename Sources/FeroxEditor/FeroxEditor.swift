import Ferox
import Foundation

#if canImport(AppKit) && canImport(MetalKit)
    import AppKit
#endif

/// `FeroxEditor` — a scene editor built on `EditorSession`, `GameHost` and Ferox UI.
///
/// ```
/// swift run FeroxEditor                 # new scene
/// swift run FeroxEditor path/to.fxscene # open a scene
/// ```
///
/// Panels: a toolbar (Play/Pause/Step/Stop, New/Open/Save, Undo/Redo, Add, Duplicate,
/// Delete), the hierarchy on the left and the inspector (name and transform) on the right.
/// The viewport camera orbits with the right mouse button, zooms with the scroll wheel and
/// pans its pivot with W/A/S/D while the pointer is not over a panel.
///
/// The editor needs a Mac with Metal. Elsewhere it explains that and exits; the editing
/// logic itself (`EditorSession`) is platform independent and covered by tests.
@main
enum FeroxEditorMain {
    @MainActor
    static func main() {
        #if canImport(AppKit) && canImport(MetalKit)
            var config = EngineConfiguration(title: "Ferox Editor")
            config.isEditMode = true
            config.windowSize = Vec2(1600, 900)
            let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
            let editor = EditorController(openPath: path)
            GameHost.run(editor, configuration: config) { host in editor.attach(host) }
        #else
            print(
                "FeroxEditor needs macOS with Metal. The editing core (EditorSession) is available headlessly through the Ferox module."
            )
            exit(1)
        #endif
    }
}

#if canImport(AppKit) && canImport(MetalKit)
    /// Built-in primitive assets every editor scene can reference by id.
    enum EditorAssets {
        static let cube = AssetID("editor.cube")
        static let sphere = AssetID("editor.sphere")
        static let plane = AssetID("editor.plane")
        static let material = AssetID("editor.default-material")

        static func register(in assets: AssetManager) {
            assets.registerMesh(.cube(), id: cube)
            assets.registerMesh(.sphere(radius: 0.5, segments: 32, rings: 16), id: sphere)
            assets.registerMesh(.plane(size: 20, subdivisions: 1), id: plane)
            var m = MaterialData(id: material, name: "Default")
            m.baseColor = Color(0.8, 0.8, 0.8, 1)
            m.roughness = 0.6
            assets.registerMaterial(m)
        }
    }

    /// Owns the session, the editor camera and the panels. Runs as the engine's `Game`, but
    /// in edit mode only `setup` and `shutdown` are called; per-frame work happens in the
    /// host's `onFrame` hook so it also runs while editing.
    final class EditorController: Game {
        private let openPath: String?
        private var session: EditorSession!
        private weak var host: GameHost?
        private var editorCamera = Entity.null
        // Orbit camera state.
        private var pivot = Vec3(0, 0.5, 0)
        private var yaw: Float = 0.6
        private var pitch: Float = -0.45
        private var distance: Float = 12

        // Panels.
        private let status = UILabel("")
        private var playButton: UIButton!
        private var pauseButton: UIButton!
        private var hierarchy: UIListView!
        private var rows: [(entity: Entity, depth: Int)] = []
        private let nameField = UITextField(placeholder: "Name")
        private let componentsLabel = UILabel("")
        /// Position x/y/z, rotation (degrees) x/y/z, scale x/y/z.
        private var sliders: [UISlider] = []
        private var sliderLabels: [UILabel] = []

        init(openPath: String?) { self.openPath = openPath }

        /// Called by `GameHost.run` before `setup`.
        @MainActor
        func attach(_ host: GameHost) {
            self.host = host
            host.onFrame = { [weak self] time in
                MainActor.assumeIsolated { self?.frame(time) }
            }
        }

        func setup(engine: Engine) throws {
            session = EditorSession(engine: engine)
            EditorAssets.register(in: engine.assets)

            editorCamera = engine.world.createEntity(named: "Editor Camera")
            var camera = Camera.perspective(fov: 55, near: 0.05, far: 2000)
            camera.priority = 1000  // wins over scene cameras while editing
            engine.world.add(camera, to: editorCamera)
            session.editorEntities = [editorCamera]

            if let openPath {
                try session.load(from: URL(fileURLWithPath: openPath))
            } else {
                buildDefaultScene(engine.world)
            }
            buildPanels(engine)
            session.onChange = { [weak self] in self?.refresh() }
            refresh()
        }

        func shutdown(engine: Engine) {
            session.onChange = nil
        }

        // MARK: Scene

        private func buildDefaultScene(_ world: World) {
            let ground = world.createEntity(named: "Ground")
            world.add(MeshRenderer(mesh: EditorAssets.plane, materials: [EditorAssets.material]), to: ground)
            world.add(Collider3D.box(Vec3(20, 0.2, 20)), to: ground)
            let cube = world.createEntity(named: "Cube", transform: Transform(position: Vec3(0, 0.5, 0)))
            world.add(MeshRenderer(mesh: EditorAssets.cube, materials: [EditorAssets.material]), to: cube)
            let sun = world.createEntity(
                named: "Sun", transform: Transform(rotation: .lookRotation(forward: Vec3(-0.5, -1, -0.3).normalized)))
            world.add(Light.directional(), to: sun)
            let cam = world.createEntity(
                named: "Main Camera",
                transform: Transform(
                    position: Vec3(0, 3, 8), rotation: .lookRotation(forward: Vec3(0, -3, -8).normalized)))
            world.add(Camera.perspective(), to: cam)
            world.add(Environment(), to: world.createEntity(named: "Environment"))
            TransformSystem.update(world)
        }

        /// Adds a primitive in front of the pivot as one undoable step.
        private func add(_ kind: String) {
            guard session.state == .editing else { return }
            let world = session.engine.world
            let e = session.createEntity(named: kind)
            world.add(Transform(position: pivot), to: e)
            switch kind {
            case "Cube": world.add(MeshRenderer(mesh: EditorAssets.cube, materials: [EditorAssets.material]), to: e)
            case "Sphere": world.add(MeshRenderer(mesh: EditorAssets.sphere, materials: [EditorAssets.material]), to: e)
            case "Light": world.add(Light(type: .point, color: .white, intensity: 20, range: 10), to: e)
            case "Camera": world.add(Camera.perspective(), to: e)
            default: break
            }
            TransformSystem.update(world)
            refresh()
        }

        // MARK: Panels

        private func buildPanels(_ engine: Engine) {
            let ui = engine.ui
            func button(_ title: String, _ action: @escaping () -> Void) -> UIButton { UIButton(title, action: action) }

            playButton = button("Play") { [unowned self] in
                self.session.state == .editing ? self.session.play() : self.session.stop()
            }
            pauseButton = button("Pause") { [unowned self] in self.session.togglePause() }
            let toolbar = UIStack(
                .horizontal, spacing: 6,
                [
                    playButton, pauseButton,
                    button("Step") { [unowned self] in self.session.step() },
                    button("New") { [unowned self] in self.perform { try self.session.newScene() } },
                    button("Open…") { [unowned self] in MainActor.assumeIsolated { self.openScene() } },
                    button("Save…") { [unowned self] in MainActor.assumeIsolated { self.saveScene() } },
                    button("Undo") { [unowned self] in self.session.undo() },
                    button("Redo") { [unowned self] in self.session.redo() },
                    button("+Cube") { [unowned self] in self.add("Cube") },
                    button("+Sphere") { [unowned self] in self.add("Sphere") },
                    button("+Light") { [unowned self] in self.add("Light") },
                    button("+Camera") { [unowned self] in self.add("Camera") },
                    button("+Empty") { [unowned self] in self.add("Empty") },
                    button("Duplicate") { [unowned self] in self.session.duplicateSelection() },
                    button("Delete") { [unowned self] in self.session.deleteSelection() },
                ])
            toolbar.padding = EdgeInsets(all: 6)
            toolbar.background = Color(0.1, 0.1, 0.12, 0.9)
            toolbar.cornerRadius = 8
            toolbar.anchors = .point(Vec2(0, 0), size: Vec2(1500, 44), pivot: Vec2(0, 0), offset: Vec2(12, 12))
            ui.add(toolbar)

            hierarchy = UIListView(count: 0, rowHeight: 26) { [unowned self] i in
                let row = self.rows.indices.contains(i) ? self.rows[i] : (entity: Entity.null, depth: 0)
                let label = UILabel(
                    String(repeating: "   ", count: min(row.depth, 12)) + self.session.displayName(of: row.entity))
                label.padding = EdgeInsets(horizontal: 8, vertical: 4)
                return label
            }
            hierarchy.height = .fill(1)
            hierarchy.onSelect = { [unowned self] i in
                if self.rows.indices.contains(i) { self.session.select(self.rows[i].entity) }
            }
            let left = UIStack(.vertical, spacing: 6, [UILabel("Hierarchy"), hierarchy])
            left.padding = EdgeInsets(all: 10)
            left.background = Color(0.1, 0.1, 0.12, 0.9)
            left.cornerRadius = 8
            left.anchors = .point(Vec2(0, 0), size: Vec2(260, 640), pivot: Vec2(0, 0), offset: Vec2(12, 66))
            ui.add(left)

            nameField.onSubmit = { [unowned self] text in
                if let e = self.session.selection { self.session.rename(e, to: text) }
            }
            var inspectorRows: [UIElement] = [UILabel("Inspector"), nameField]
            let groups: [(String, ClosedRange<Float>)] = [
                ("Position", -50...50), ("Rotation", -180...180), ("Scale", 0.01...10),
            ]
            for (g, range) in groups {
                inspectorRows.append(UILabel(g))
                for axis in ["X", "Y", "Z"] {
                    let label = UILabel("\(axis) 0")
                    label.width = .fixed(90)
                    let slider = UISlider(value: 0, range: range) { [unowned self] _ in self.applyInspector() }
                    slider.width = .fill(1)
                    sliders.append(slider)
                    sliderLabels.append(label)
                    inspectorRows.append(UIStack(.horizontal, spacing: 6, [label, slider]))
                }
            }
            inspectorRows.append(componentsLabel)
            componentsLabel.wraps = true
            let right = UIStack(.vertical, spacing: 6, inspectorRows)
            right.padding = EdgeInsets(all: 10)
            right.background = Color(0.1, 0.1, 0.12, 0.9)
            right.cornerRadius = 8
            right.anchors = .point(Vec2(1, 0), size: Vec2(340, 640), pivot: Vec2(1, 0), offset: Vec2(-12, 66))
            ui.add(right)

            status.anchors = .point(Vec2(0, 1), size: Vec2(900, 28), pivot: Vec2(0, 1), offset: Vec2(12, -12))
            ui.add(status)
        }

        /// Rebuilds the hierarchy rows and the inspector from the session.
        private func refresh() {
            let world = session.engine.world
            rows = []
            for r in session.sceneRoots { world.visitSubtree(r) { e, depth in rows.append((e, depth)) } }
            hierarchy.count = rows.count  // resets the virtualised rows
            if let sel = session.selection, let i = rows.firstIndex(where: { $0.entity == sel }) {
                if hierarchy.selectedIndex != i { hierarchy.select(i) }
            }
            playButton.label.text = session.state == .editing ? "Play" : "Stop"
            pauseButton.label.text = session.state == .paused ? "Resume" : "Pause"

            guard let e = session.selection, let t = world.get(Transform.self, e) else {
                nameField.text = ""
                componentsLabel.text = "Nothing selected"
                for (s, l) in zip(sliders, sliderLabels) {
                    s.value = 0
                    l.text = "—"
                }
                return
            }
            nameField.text = session.displayName(of: e)
            let euler = t.rotation.eulerAngles * (180 / .pi)
            let values = [
                t.position.x, t.position.y, t.position.z, euler.x, euler.y, euler.z, t.scale.x, t.scale.y, t.scale.z,
            ]
            let axes = ["X", "Y", "Z"]
            for (i, v) in values.enumerated() {
                // Assigning `value` directly (not `setValue`) does not fire `onChange`.
                sliders[i].value = min(max(v, sliders[i].range.lowerBound), sliders[i].range.upperBound)
                sliderLabels[i].text = "\(axes[i % 3]) \(String(format: "%.2f", v))"
            }
            let names = world.components(of: e).map { String(describing: type(of: $0)) }.sorted()
            componentsLabel.text = "Components: " + names.joined(separator: ", ")
        }

        /// Writes the slider values back to the selected entity (one coalesced undo step).
        private func applyInspector() {
            guard let e = session.selection, var t = session.engine.world.get(Transform.self, e) else { return }
            let v = sliders.map(\.value)
            t.position = Vec3(v[0], v[1], v[2])
            let r = Vec3(v[3], v[4], v[5]) * (.pi / 180)
            t.rotation = Quat(pitch: r.x, yaw: r.y, roll: r.z)
            t.scale = Vec3(max(v[6], 0.01), max(v[7], 0.01), max(v[8], 0.01))
            session.setTransform(t, of: e)
            let axes = ["X", "Y", "Z"]
            for i in 0..<9 { sliderLabels[i].text = "\(axes[i % 3]) \(String(format: "%.2f", v[i]))" }
        }

        // MARK: Files

        private func perform(_ body: () throws -> Void) {
            do { try body() } catch { status.text = "Error: \(error)" }
        }

        @MainActor
        private func openScene() {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            perform { try session.load(from: url) }
        }

        @MainActor
        private func saveScene() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (session.fileURL?.lastPathComponent) ?? "\(session.sceneName).fxscene"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            perform { try session.save(to: url) }
        }

        // MARK: Per frame

        @MainActor
        private func frame(_ time: FrameTime) {
            guard let host, session != nil else { return }
            let engine = session.engine
            let world = engine.world
            let input = engine.input.state
            let overPanel = engine.ui.hitTest(input.mousePosition) != nil

            // The editor camera only renders while editing; in play mode the game's cameras win.
            let editing = session.state == .editing
            if editing && world.has(Disabled.self, editorCamera) { world.remove(Disabled.self, from: editorCamera) }
            if !editing && !world.has(Disabled.self, editorCamera) { world.add(Disabled(), to: editorCamera) }

            if editing {
                updateOrbitCamera(
                    input, dt: Float(time.unscaledDelta), overPanel: overPanel, typing: engine.ui.wantsKeyboard)
                if !engine.ui.wantsKeyboard {
                    if input.wasPressed(Key.delete) || input.wasPressed(Key.backspace) { session.deleteSelection() }
                    if input.wasPressed(Key.escape) { session.select(nil) }
                }
                if input.wasPressed(MouseButton.left), !overPanel,
                    let camera = world.get(Camera.self, editorCamera),
                    let m = world.get(WorldTransform.self, editorCamera)?.matrix
                {
                    let size = engine.viewportPoints
                    let ray = camera.ray(
                        through: input.mousePosition / size, aspect: size.x / max(size.y, 1), cameraToWorld: m)
                    let pixel = (x: Int(input.mousePosition.x), y: Int(input.mousePosition.y))
                    session.select(session.pick(ray, pixel: pixel))
                    if let serial = session.gpuPickSerial {
                        host.renderer.scheduleInstancePick(
                            x: pixel.x, y: pixel.y, serial: serial,
                            viewWidth: Int(size.x), viewHeight: Int(size.y))
                    }
                }
                if let sample = host.renderer.takeInstancePick(),
                    let entity = session.completeInstancePick(
                        serial: sample.serial, instance: sample.instance, entities: sample.entities)
                {
                    session.select(entity)
                }
                drawGizmos(host.renderer.debugDraw)
            }
            let dirty = session.isDirty ? " (edited)" : ""
            status.text =
                "\(session.sceneName)\(dirty) · \(String(describing: session.state)) · \(session.sceneEntities.count) entities · "
                + String(
                    format: "%.1f ms CPU, %.1f ms GPU", host.renderer.statistics.cpuMilliseconds,
                    host.renderer.statistics.gpuMilliseconds ?? 0)
        }

        private func updateOrbitCamera(_ input: InputState, dt: Float, overPanel: Bool, typing: Bool) {
            let world = session.engine.world
            if input.isDown(MouseButton.right) {
                yaw -= input.mouseDelta.x * 0.008
                pitch = min(max(pitch - input.mouseDelta.y * 0.008, -1.5), 1.5)
            }
            if !overPanel { distance = min(max(distance * (1 - input.scrollDelta.y * 0.05), 0.5), 500) }
            if !typing {
                let forward = Vec3(-sin(yaw), 0, -cos(yaw))
                let right = Vec3(cos(yaw), 0, -sin(yaw))
                var move = Vec3.zero
                if input.isDown(Key.w) { move += forward }
                if input.isDown(Key.s) { move -= forward }
                if input.isDown(Key.d) { move += right }
                if input.isDown(Key.a) { move -= right }
                pivot += move * (dt * max(distance, 2))
            }
            let dir = Vec3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
            let position = pivot - dir * distance
            world.add(Transform(position: position, rotation: .lookRotation(forward: dir)), to: editorCamera)
        }

        /// Ground grid, selection axes and bounds, and light/camera markers.
        private func drawGizmos(_ debug: DebugDraw) {
            let world = session.engine.world
            let grid = Color(0.5, 0.5, 0.5, 0.35)
            for i in -10...10 {
                let f = Float(i)
                debug.line(Vec3(f, 0, -10), Vec3(f, 0, 10), grid)
                debug.line(Vec3(-10, 0, f), Vec3(10, 0, f), grid)
            }
            world.read(Light.self) { e, light in
                guard let m = world.get(WorldTransform.self, e)?.matrix else { return }
                let p = m.translation
                debug.cross(p, size: 0.3, Color(1, 0.9, 0.3, 1))
                if light.type != .point {
                    debug.arrow(from: p, to: p + m.transformDirection(.forward).normalized * 1.5, Color(1, 0.9, 0.3, 1))
                }
            }
            world.read(Camera.self) { e, _ in
                guard e != editorCamera, let m = world.get(WorldTransform.self, e)?.matrix else { return }
                debug.arrow(
                    from: m.translation, to: m.translation + m.transformDirection(.forward).normalized,
                    Color(0.4, 0.8, 1, 1))
            }
            guard let e = session.selection, let m = world.get(WorldTransform.self, e)?.matrix else { return }
            let p = m.translation
            debug.arrow(from: p, to: p + m.transformDirection(Vec3(1, 0, 0)).normalized, Color(1, 0.2, 0.2, 1))
            debug.arrow(from: p, to: p + m.transformDirection(Vec3(0, 1, 0)).normalized, Color(0.2, 1, 0.2, 1))
            debug.arrow(from: p, to: p + m.transformDirection(Vec3(0, 0, 1)).normalized, Color(0.3, 0.5, 1, 1))
            if let mesh = world.get(MeshRenderer.self, e)?.mesh,
                let bounds = session.engine.assets.mesh(mesh)?.value?.bounds,
                !bounds.isEmpty
            {
                debug.box(bounds, transform: m, Color(1, 0.6, 0.1, 1))
            }
        }
    }
#endif
