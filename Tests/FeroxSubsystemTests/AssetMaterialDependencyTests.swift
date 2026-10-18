/// Regression test: a `.fxmat` material's dependencies resolve its texture asset IDs to project paths,
/// even when a cold scan reaches the material before the texture it references.
import XCTest
import FeroxCore
@testable import FeroxAssets

final class AssetMaterialDependencyTests: XCTestCase {
    func testMaterialDependsOnReferencedTexturePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetMaterialDependencyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("\(dir)/tex.png"))
        }
        let database = AssetDatabase(root: root)
        _ = database.refresh()

        // Each material references the texture in the other directory, so whichever directory a
        // scan visits first, one material is seen before its texture.
        for (dir, other) in [("a", "b"), ("b", "a")] {
            var material = MaterialData(name: dir)
            material.baseColorTexture = try XCTUnwrap(database.id(forPath: "\(other)/tex.png"))
            try JSONEncoder().encode(material).write(to: root.appendingPathComponent("\(dir)/mat.fxmat"))
        }
        _ = database.refresh()

        let cold = AssetDatabase(root: root)
        _ = cold.refresh()
        for db in [database, cold] {
            for (dir, other) in [("a", "b"), ("b", "a")] {
                let id = try XCTUnwrap(db.id(forPath: "\(dir)/mat.fxmat"))
                XCTAssertEqual(db.entry(id)?.meta.dependencies, ["\(other)/tex.png"])
            }
        }
    }
}
