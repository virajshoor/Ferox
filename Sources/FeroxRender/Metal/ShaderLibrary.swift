#if canImport(Metal)
    import FeroxCore
    import Foundation
    import Metal

    /// Function-constant selection for the mesh shaders (indices match `Common.metal`).
    public struct ShaderVariant: Hashable, Sendable {
        public var skinning = false
        public var alphaTest = false
        public var vertexColor = false
        public var clusters = true
        public var unlit = false
        /// Sample material textures from the tier-2 argument buffer instead of texture slots 0...4.
        public var materialArguments = false
        public init(
            skinning: Bool = false, alphaTest: Bool = false, vertexColor: Bool = false, clusters: Bool = true,
            unlit: Bool = false, materialArguments: Bool = false
        ) {
            self.skinning = skinning
            self.alphaTest = alphaTest
            self.vertexColor = vertexColor
            self.clusters = clusters
            self.unlit = unlit
            self.materialArguments = materialArguments
        }

        var constantValues: MTLFunctionConstantValues {
            let v = MTLFunctionConstantValues()
            // Index 5 selects the argument buffer. Index 6 is its complement so the discrete
            // texture arguments stay present on the default path.
            var flags = [skinning, alphaTest, vertexColor, clusters, unlit, materialArguments, !materialArguments]
            for i in flags.indices { v.setConstantValue(&flags[i], type: .bool, index: i) }
            return v
        }

        var key: String {
            "\(skinning ? 1 : 0)\(alphaTest ? 1 : 0)\(vertexColor ? 1 : 0)\(clusters ? 1 : 0)\(unlit ? 1 : 0)\(materialArguments ? 1 : 0)"
        }
    }

    /// Compiles Ferox's MSL sources at runtime and caches functions and pipeline states.
    ///
    /// Each `.metal` module is compiled as its own library with `Common.metal` prepended, so
    /// module-private structs never collide. Sources come from the package bundle, or from
    /// the directory named by the `FEROX_SHADER_DIR` environment variable, which also enables
    /// hot reload: `reloadIfChanged()` recompiles edited modules, keeps the previous library
    /// when compilation fails (logging the compiler output), and bumps `generation` so that
    /// dependent pipeline caches are rebuilt.
    ///
    /// Shader source is only ever read from those two locations; nothing is downloaded.
    public final class ShaderLibrary {
        /// Every shader module, in compilation order.
        public static let modules = [
            "Mesh", "Post", "Sky", "Clusters", "Culling", "Debug", "Particles", "Sprite", "UI",
            "RayTracing",
        ]
        /// Modules the renderer cannot run without.
        public static let requiredModules: Set<String> = ["Mesh", "Post", "Sky", "Sprite", "UI", "Debug"]

        public let device: any MTLDevice
        public let sourceDirectory: URL
        public let hotReloadEnabled: Bool
        /// Incremented whenever any module is recompiled.
        public private(set) var generation: UInt64 = 0
        /// Modules that failed to compile, with the compiler message.
        public private(set) var failures: [String: String] = [:]

        private var libraries: [String: any MTLLibrary] = [:]
        private var functionModule: [String: String] = [:]
        private var functions: [String: any MTLFunction] = [:]
        private var renderPipelines: [String: any MTLRenderPipelineState] = [:]
        private var computePipelines: [String: any MTLComputePipelineState] = [:]
        private var modificationDates: [String: Date] = [:]
        private var lastPoll: Double = 0
        /// Pipelines recorded here are serialised by `saveBinaryArchive` for the next launch.
        private var binaryArchive: (any MTLBinaryArchive)?

        public init(device: any MTLDevice, sourceDirectory: URL? = nil) throws {
            self.device = device
            let env = ProcessInfo.processInfo.environment["FEROX_SHADER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            let metallib = ProcessInfo.processInfo.environment["FEROX_METALLIB"].flatMap { $0.isEmpty ? nil : $0 }
            if let dir = sourceDirectory {
                self.sourceDirectory = dir
                hotReloadEnabled = true
            } else if let env {
                self.sourceDirectory = URL(fileURLWithPath: env, isDirectory: true).standardizedFileURL
                hotReloadEnabled = true
            } else if let bundled = Bundle.module.url(forResource: "Shaders", withExtension: nil) {
                self.sourceDirectory = bundled
                hotReloadEnabled = false
            } else {
                throw RenderError.shaderSourceMissing("Shaders (bundle resource)")
            }
            let policy = ShaderSourcePolicy.resolve(
                shaderDirectorySet: hotReloadEnabled, metallibPresent: metallib != nil)
            if policy == .compiledMetallib, let metallib {
                let lib = try device.makeLibrary(URL: URL(fileURLWithPath: metallib))
                lib.label = "Ferox.Metallib"
                install(lib, module: "FeroxShaders")
                generation &+= 1
                return
            }
            if !hotReloadEnabled,
                let bundled = Bundle.module.url(forResource: "FeroxShaders", withExtension: "metallib")
            {
                let lib = try device.makeLibrary(URL: bundled)
                lib.label = "Ferox.Metallib"
                install(lib, module: "FeroxShaders")
                generation &+= 1
                return
            }
            try compileAll()
        }

        // MARK: Compilation

        private func url(_ module: String) -> URL { sourceDirectory.appendingPathComponent("\(module).metal") }

        private func readSource(_ module: String) throws -> String {
            let u = url(module)
            guard let s = try? String(contentsOf: u, encoding: .utf8) else {
                throw RenderError.shaderSourceMissing(u.path)
            }
            return s
        }

        private func modificationDate(_ module: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url(module).path))?[.modificationDate] as? Date
        }

        private static func compileOptions() -> MTLCompileOptions {
            let o = MTLCompileOptions()
            o.languageVersion = .version3_0
            // The forward pass re-rasterises prepass geometry with an `equal`-style depth test,
            // which requires bit-identical vertex positions across pipelines.
            o.preserveInvariance = true
            return o
        }

        private func compile(_ module: String, common: String) -> Result<any MTLLibrary, RenderError> {
            do {
                let body = try readSource(module)
                let source = common + "\n#line 1 \"\(module).metal\"\n" + body
                let lib = try device.makeLibrary(source: source, options: Self.compileOptions())
                lib.label = "Ferox.\(module)"
                return .success(lib)
            } catch let e as RenderError {
                return .failure(e)
            } catch {
                return .failure(.shaderCompilation(file: "\(module).metal", message: "\(error)"))
            }
        }

        private func compileAll() throws {
            let common = try readSource("Common")
            let modules = Self.modules
            var results = [Result<any MTLLibrary, RenderError>?](repeating: nil, count: modules.count)
            let lock = NSLock()
            // Modules are independent; compile them in parallel (MTLDevice is thread-safe).
            DispatchQueue.concurrentPerform(iterations: modules.count) { i in
                let r = compile(modules[i], common: common)
                lock.lock()
                results[i] = r
                lock.unlock()
            }
            for (i, m) in modules.enumerated() {
                switch results[i] {
                case .success(let lib)?:
                    install(lib, module: m)
                    failures[m] = nil
                case .failure(let e)?:
                    failures[m] = e.description
                    if Self.requiredModules.contains(m) { throw e }
                    Log.warning("Shaders", "Optional module \(m) unavailable: \(e)")
                case nil:
                    break
                }
            }
            modificationDates = Dictionary(
                uniqueKeysWithValues: (["Common"] + modules).compactMap { m in
                    modificationDate(m).map { (m, $0) }
                })
            generation &+= 1
        }

        private func install(_ lib: any MTLLibrary, module: String) {
            libraries[module] = lib
            functionModule = functionModule.filter { $0.value != module }
            for name in lib.functionNames { functionModule[name] = module }
        }

        /// Polls source modification dates (at most twice a second) and recompiles changed
        /// modules. Returns true when anything was rebuilt. A failed compile keeps the previous
        /// library and logs the error, so a typo never takes the running game down.
        @discardableResult
        public func reloadIfChanged() -> Bool {
            guard hotReloadEnabled else { return false }
            let now = MonotonicClock.now()
            guard now - lastPoll >= 0.5 else { return false }
            lastPoll = now
            var changed: [String] = []
            for m in ["Common"] + Self.modules {
                let d = modificationDate(m)
                if d != modificationDates[m] {
                    changed.append(m)
                    modificationDates[m] = d
                }
            }
            guard !changed.isEmpty else { return false }
            let targets = changed.contains("Common") ? Self.modules : changed
            guard let common = try? readSource("Common") else {
                Log.error("Shaders", "Hot reload: Common.metal could not be read")
                return false
            }
            var rebuilt = false
            for m in targets {
                switch compile(m, common: common) {
                case .success(let lib):
                    install(lib, module: m)
                    failures[m] = nil
                    rebuilt = true
                    Log.info("Shaders", "Reloaded \(m).metal")
                case .failure(let e):
                    failures[m] = e.description
                    Log.error("Shaders", "Hot reload kept the previous \(m) library: \(e)")
                }
            }
            if rebuilt {
                functions.removeAll()
                renderPipelines.removeAll()
                computePipelines.removeAll()
                generation &+= 1
            }
            return rebuilt
        }

        // MARK: Lookup

        public func hasFunction(_ name: String) -> Bool { functionModule[name] != nil }

        /// Whether every function of `module` is available (e.g. "RayTracing").
        public func isAvailable(_ module: String) -> Bool { libraries[module] != nil }

        /// A function by name, specialised with `variant` when given. `fullscreenVertex` exists
        /// in every module; pass `module` to pick the copy that shares a library with its
        /// fragment function (required for a valid pipeline).
        public func function(_ name: String, variant: ShaderVariant? = nil, module: String? = nil) throws
            -> any MTLFunction
        {
            let mod = module ?? functionModule[name]
            guard let mod, let lib = libraries[mod] else { throw RenderError.functionMissing(name) }
            let key = "\(mod).\(name).\(variant?.key ?? "-")"
            if let f = functions[key] { return f }
            let f: any MTLFunction
            if let variant {
                do {
                    f = try lib.makeFunction(name: name, constantValues: variant.constantValues)
                } catch {
                    throw RenderError.shaderCompilation(
                        file: "\(mod).metal", message: "\(name) [\(variant.key)]: \(error)")
                }
            } else {
                guard let plain = lib.makeFunction(name: name) else { throw RenderError.functionMissing(name) }
                f = plain
            }
            f.label = name
            functions[key] = f
            return f
        }

        /// The module that defines `name`.
        public func module(of name: String) -> String? { functionModule[name] }

        /// A cached render pipeline. `key` must uniquely describe everything `configure` sets.
        public func renderPipeline(
            _ key: String,
            _ configure: (MTLRenderPipelineDescriptor) throws -> Void
        ) throws -> any MTLRenderPipelineState {
            if let p = renderPipelines[key] { return p }
            let d = MTLRenderPipelineDescriptor()
            d.label = key
            if let binaryArchive { d.binaryArchives = [binaryArchive] }
            try configure(d)
            do {
                let p = try device.makeRenderPipelineState(descriptor: d)
                try? binaryArchive?.addRenderPipelineFunctions(descriptor: d)
                renderPipelines[key] = p
                return p
            } catch {
                throw RenderError.pipeline(name: key, message: "\(error)")
            }
        }

        /// A cached compute pipeline for kernel `name`.
        public func computePipeline(_ name: String) throws -> any MTLComputePipelineState {
            if let p = computePipelines[name] { return p }
            let f = try function(name)
            do {
                let p = try device.makeComputePipelineState(function: f)
                computePipelines[name] = p
                return p
            } catch {
                throw RenderError.pipeline(name: name, message: "\(error)")
            }
        }

        /// Number of cached pipeline states (diagnostics).
        public var cachedPipelineCount: Int { renderPipelines.count + computePipelines.count }

        /// Opens a binary archive at `url` (creating it when absent) so the next
        /// `renderPipeline` calls are recorded. Missing archives are not an error.
        public func openBinaryArchive(at url: URL) {
            let desc = MTLBinaryArchiveDescriptor()
            if FileManager.default.fileExists(atPath: url.path) { desc.url = url }
            binaryArchive = try? device.makeBinaryArchive(descriptor: desc)
        }

        public func saveBinaryArchive(to url: URL) {
            try? binaryArchive?.serialize(to: url)
        }
    }
#endif
