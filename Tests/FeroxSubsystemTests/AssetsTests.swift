import FeroxCore
/// Tests for the asset layer: procedural mesh geometry and validation, in-memory registration
/// with revision tracking, the Netpbm image decoder, a minimal glTF import, path containment and
/// database discovery over a temporary directory. No GPU, network or AppKit is involved.
import XCTest

@testable import FeroxAssets

final class AssetsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeroxAssetsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    /// Writes `data` to `relative` inside the temporary root, creating intermediate folders.
    private func write(_ data: Data, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// True when `error` is an AssetError.corrupt value.
    private func isCorrupt(_ error: Error) -> Bool {
        if case .corrupt? = error as? AssetError { return true }
        return false
    }

    /// True when `error` is an AssetError.unsupportedFormat value.
    private func isUnsupported(_ error: Error) -> Bool {
        if case .unsupportedFormat? = error as? AssetError { return true }
        return false
    }

    /// The unit cube has 24 unique vertices (four per face), 12 triangles and bounds of ±0.5.
    func testCubeHasExpectedCountsAndBounds() throws {
        let cube = MeshData.cube()
        XCTAssertEqual(cube.vertexCount, 24)
        XCTAssertEqual(cube.triangleCount, 12)
        XCTAssertEqual(cube.indices.count, 36)
        XCTAssertEqual(cube.bounds.min.x, -0.5, accuracy: 1e-5)
        XCTAssertEqual(cube.bounds.max.y, 0.5, accuracy: 1e-5)
        XCTAssertNoThrow(try cube.validate())
    }

    /// The UV sphere has (rings + 1) x (segments + 1) vertices lying on its radius.
    func testSphereTessellationMatchesParametersAndRadius() {
        let sphere = MeshData.sphere(radius: 0.5, segments: 32, rings: 16)
        XCTAssertEqual(sphere.vertexCount, 17 * 33)
        XCTAssertEqual(sphere.triangleCount, 16 * 32 * 2)
        let worstRadialError = sphere.positions.map { abs($0.length - 0.5) }.max() ?? 1
        XCTAssertLessThan(worstRadialError, 1e-4)
        XCTAssertEqual(sphere.bounds.max.y, 0.5, accuracy: 1e-4)
    }

    /// A two-by-two subdivided plane lies flat on y = 0 with upward normals.
    func testSubdividedPlaneIsFlatWithUpwardNormals() {
        let plane = MeshData.plane(size: 1, subdivisions: 2)
        XCTAssertEqual(plane.vertexCount, 9)
        XCTAssertEqual(plane.triangleCount, 8)
        XCTAssertEqual(plane.bounds.min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(plane.bounds.max.y, 0, accuracy: 1e-6)
        XCTAssertTrue(plane.normals.allSatisfy { $0 == Vec3(0, 1, 0) })
    }

    /// Validation rejects an index that points past the end of the vertex stream.
    func testValidateRejectsOutOfRangeIndex() {
        let mesh = MeshData(name: "Bad", positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)], indices: [0, 1, 5])
        XCTAssertThrowsError(try mesh.validate()) { XCTAssertTrue(self.isCorrupt($0)) }
    }

    /// Validation rejects a vertex attribute stream whose length differs from the position count.
    func testValidateRejectsMismatchedAttributeCount() {
        var mesh = MeshData(name: "Bad", positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)], indices: [0, 1, 2])
        mesh.normals = [Vec3(0, 0, 1)]
        XCTAssertThrowsError(try mesh.validate()) { XCTAssertTrue(self.isCorrupt($0)) }
    }

    /// Generated normals of a counter-clockwise triangle in the XY plane point along +Z.
    func testGenerateNormalsFollowsWindingOrder() {
        var mesh = MeshData(name: "Tri", positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)], indices: [0, 1, 2])
        mesh.generateNormals()
        XCTAssertEqual(mesh.normals.count, 3)
        for n in mesh.normals {
            XCTAssertEqual(n.z, 1, accuracy: 1e-5)
        }
    }

    /// Re-registering a mesh under the same id reuses its handle and bumps the revision; unknown ids return nil.
    func testRegisterMeshReusesHandleAndBumpsRevision() {
        let manager = AssetManager(database: nil)
        let id = AssetID("test/mesh")
        let first = manager.registerMesh(MeshData.cube(), id: id)
        let second = manager.registerMesh(MeshData.sphere(), id: id)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.revision, 2)
        XCTAssertTrue(second.isLoaded)
        XCTAssertEqual(manager.mesh(id)?.value?.vertexCount, MeshData.sphere().vertexCount)
        XCTAssertNil(manager.mesh(AssetID("test/missing")))
    }

    /// Registering a material makes it readable immediately and bumps its revision on each update.
    func testRegisterMaterialIsReadableAndBumpsRevision() {
        let manager = AssetManager(database: nil)
        let material = MaterialData(name: "Metal")
        let handle = manager.registerMaterial(material)
        XCTAssertEqual(handle.revision, 1)
        XCTAssertEqual(manager.loadedMaterial(material.id)?.name, "Metal")

        manager.registerMaterial(material)
        XCTAssertEqual(handle.revision, 2)
    }

    /// Resident texture bytes are the sum of registered image byte counts (a 4 x 4 RGBA8 image is 64 bytes).
    func testRegisteredTextureCountsResidentBytes() {
        let manager = AssetManager(database: nil)
        manager.registerTexture(ImageData.checkerboard(size: 4), id: AssetID("test/checker"))
        XCTAssertEqual(manager.residentTextureBytes, 64)
        XCTAssertEqual(manager.loadedTextureCount, 1)
    }

    /// A P6 Netpbm image decodes to RGBA with opaque alpha, and a truncated raster is rejected.
    func testNetpbmDecodesAndTruncatedRasterIsRejected() throws {
        let header = Data("P6\n2 2\n255\n".utf8)
        let raster = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9])
        let image = try ImageDecoder.decode(header + raster, "test.ppm")
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixels.count, 16)
        XCTAssertEqual(Array(image.pixels.prefix(4)), [255, 0, 0, 255])

        XCTAssertThrowsError(try ImageDecoder.decode(header + Data([1, 2, 3]), "truncated.ppm")) {
            XCTAssertTrue(self.isCorrupt($0))
        }
    }

    /// A minimal glTF document produces a node hierarchy with the scene's root nodes.
    func testMinimalGLTFBuildsNodeHierarchy() throws {
        let json = """
            {"asset":{"version":"2.0"},"scenes":[{"nodes":[0]}],
             "nodes":[{"name":"Root","children":[1]},{"name":"Child"}]}
            """
        let model = try GLTFImporter(imageDecoder: nil).load(data: Data(json.utf8), name: "minimal")
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertEqual(model.roots, [0])
        XCTAssertEqual(model.nodes[0].name, "Root")
        XCTAssertEqual(model.nodes[0].children, [1])
    }

    /// Malformed glTF JSON and unsupported glTF versions are rejected with an AssetError.
    func testInvalidGLTFIsRejected() {
        let importer = GLTFImporter(imageDecoder: nil)
        XCTAssertThrowsError(try importer.load(data: Data("{ not json".utf8), name: "broken")) {
            XCTAssertTrue(self.isCorrupt($0))
        }
        let v1 = Data(#"{"asset":{"version":"1.0"}}"#.utf8)
        XCTAssertThrowsError(try importer.load(data: v1, name: "old")) {
            XCTAssertTrue(self.isUnsupported($0))
        }
    }

    /// Path validation rejects traversal above the root, absolute paths and empty strings, and accepts contained paths.
    func testSafePathContainsPathsWithinRoot() throws {
        let safe = SafePath(root: root)
        XCTAssertThrowsError(try safe.resolve("../escape.txt")) {
            XCTAssertEqual($0 as? PathError, .escapesRoot("../escape.txt"))
        }
        XCTAssertThrowsError(try safe.resolve("/etc/passwd")) {
            XCTAssertEqual($0 as? PathError, .absoluteNotAllowed("/etc/passwd"))
        }
        XCTAssertThrowsError(try safe.resolve("")) {
            XCTAssertEqual($0 as? PathError, .empty)
        }
        let inside = try safe.resolve("models/../textures/checker.png")
        XCTAssertEqual(inside.lastPathComponent, "checker.png")
    }

    /// Refreshing the database discovers known asset kinds, writes .meta sidecars, ignores unknown files, and is idempotent.
    func testDatabaseRefreshDiscoversAssetsAndWritesMeta() throws {
        try write(Data([0x89, 0x50, 0x4E, 0x47]), "textures/checker.png")
        try write(Data("ignore me".utf8), "notes.txt")
        let database = AssetDatabase(root: root)

        let first = database.refresh()
        XCTAssertEqual(first.added.count, 1)
        let id = try XCTUnwrap(database.id(forPath: "textures/checker.png"))
        XCTAssertEqual(database.entry(id)?.kind, .texture)
        XCTAssertNil(database.id(forPath: "notes.txt"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("textures/checker.png.meta").path))

        XCTAssertTrue(database.refresh().isEmpty)
    }
}
