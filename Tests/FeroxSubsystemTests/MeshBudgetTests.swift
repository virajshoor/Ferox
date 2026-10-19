/// Tests for `MemoryBudget.meshBytes`: cached models are evicted LRU when unreferenced,
/// registered meshes never are.
import XCTest
import FeroxCore
@testable import FeroxAssets

final class MeshBudgetTests: XCTestCase {
    /// One triangle with an embedded base64 position buffer.
    static let triangleGLTF = #"""
    {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
     "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
     "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}],
     "bufferViews":[{"buffer":0,"byteLength":36}],
     "buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"}]}
    """#

    func testUnreferencedModelIsEvictedOverMeshBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeshBudgetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.triangleGLTF.utf8).write(to: root.appendingPathComponent("tri.gltf"))
        let database = AssetDatabase(root: root)
        _ = database.refresh()
        let id = try XCTUnwrap(database.id(forPath: "tri.gltf"))
        let manager = AssetManager(database: database, budget: MemoryBudget(textureBytes: 1 << 30, meshBytes: 1, audioBytes: 1 << 20))

        var handle: AssetHandle<LoadedModel>? = manager.model(id)
        manager.waitForPendingLoads()
        manager.update()
        XCTAssertTrue(handle?.isLoaded == true, "\(String(describing: handle?.state))")
        XCTAssertGreaterThan(manager.residentMeshBytes, 0)
        XCTAssertTrue(manager.model(id) === handle, "a referenced model must stay cached")

        // Swift 5.10 (CI) rejects `weak let`. Swift 6.2+ warns if a `weak var` is only
        // initialized, never assigned. A separate assignment is valid on both.
        weak var released: AssetHandle<LoadedModel>?
        released = handle
        handle = nil
        manager.update()
        XCTAssertNil(released, "an unreferenced model over budget must be evicted")
        XCTAssertEqual(manager.residentMeshBytes, 0)
    }

    func testRegisteredMeshesAreNeverEvicted() {
        let manager = AssetManager(database: nil, budget: MemoryBudget(textureBytes: 1 << 30, meshBytes: 1, audioBytes: 1 << 20))
        manager.registerMesh(.cube(), id: AssetID("test/cube"))
        manager.update()
        XCTAssertNotNil(manager.mesh(AssetID("test/cube"))?.value)
        XCTAssertGreaterThan(manager.residentMeshBytes, 1)
    }
}
