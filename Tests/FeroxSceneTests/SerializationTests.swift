/// Tests for scene serialization in FeroxScene: `SceneSerializer` encode and decode round
/// trips (components, hierarchy, unknown-component preservation, strict mode and rollback),
/// and `SceneDocument` validation (format version, duplicate ids, dangling and cyclic
/// parents, and size and nesting limits).
import FeroxCore
import Foundation
import XCTest
@testable import FeroxScene

private struct SavedHealth: SerializableComponent, Equatable {
    var hp: Int
}

/// A registry with only the components these tests need, so tests do not share global state.
private func makeRegistry() -> ComponentRegistry {
    let registry = ComponentRegistry()
    registry.register(Name.self)
    registry.register(Transform.self)
    registry.register(SavedHealth.self)
    return registry
}

/// Asserts that `error` is a `SceneError.malformed` value.
private func assertMalformed(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    if case .malformed? = error as? SceneError { return }
    XCTFail("expected SceneError.malformed, got \(error)", file: file, line: line)
}

final class SceneSerializerTests: XCTestCase {
    // Components on a named entity survive an encode and decode into a fresh world.
    func testComponentsRoundTrip() throws {
        let registry = makeRegistry()
        let source = World()
        let hero = source.createEntity(named: "Hero", transform: Transform(position: Vec3(1, 2, 3)))
        source.add(SavedHealth(hp: 7), to: hero)
        let doc = try SceneSerializer(registry: registry).encode(world: source, name: "Level")

        let target = World()
        let created = try SceneSerializer(registry: registry).decode(doc, into: target)
        XCTAssertEqual(created.count, 1)
        let e = try XCTUnwrap(created.first)
        XCTAssertEqual(target.get(SavedHealth.self, e), SavedHealth(hp: 7))
        XCTAssertEqual(target.get(Name.self, e)?.value, "Hero")
        XCTAssertEqual(target.get(Transform.self, e)?.position, Vec3(1, 2, 3))
    }

    // Parent and child links are rebuilt on decode, with the child listed under its parent.
    func testHierarchyRoundTrip() throws {
        let registry = makeRegistry()
        let source = World()
        let parent = source.createEntity(named: "Parent")
        _ = source.createEntity(named: "Child", parent: parent)
        let doc = try SceneSerializer(registry: registry).encode(world: source, name: "Tree")

        let target = World()
        let created = try SceneSerializer(registry: registry).decode(doc, into: target)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(target.parent(of: created[1]), created[0])
        XCTAssertEqual(target.children(of: created[0]), [created[1]])
        XCTAssertEqual(target.get(Name.self, created[1])?.value, "Child")
    }

    // Decoding under an existing entity attaches the document's root entities to it.
    func testDecodeUnderParentAttachesRoots() throws {
        let registry = makeRegistry()
        let source = World()
        _ = source.createEntity(named: "Imported")
        let doc = try SceneSerializer(registry: registry).encode(world: source, name: "Piece")

        let target = World()
        let anchor = target.createEntity(named: "Anchor")
        let created = try SceneSerializer(registry: registry).decode(doc, into: target, parent: anchor)
        XCTAssertEqual(target.parent(of: created[0]), anchor)
    }

    // Components with no registered type are kept verbatim and written back out on the next save.
    func testUnknownComponentsArePreserved() throws {
        let registry = makeRegistry()
        let payload: JSONValue = .object(["x": .number(1)])
        let doc = SceneDocument(
            name: "Unknown",
            entities: [
                SceneDocument.EntityRecord(
                    id: 0, components: ["Name": .object(["value": .string("Mystery")]), "Mystery": payload])
            ])
        let target = World()
        let created = try SceneSerializer(registry: registry).decode(doc, into: target)
        let e = try XCTUnwrap(created.first)
        XCTAssertEqual(target.get(UnknownComponents.self, e)?.payloads["Mystery"], payload)

        let resaved = try SceneSerializer(registry: registry).encode(world: target, name: "Unknown")
        XCTAssertEqual(resaved.entities.first?.components["Mystery"], payload)
    }

    // In strict mode an unknown component aborts the load and leaves no entities behind.
    func testStrictModeRejectsUnknownComponentAndRollsBack() throws {
        let registry = makeRegistry()
        let doc = SceneDocument(
            name: "Strict",
            entities: [
                SceneDocument.EntityRecord(id: 0, components: ["Mystery": .object([:])]),
                SceneDocument.EntityRecord(id: 1, components: ["Name": .object(["value": .string("Ok")])]),
            ])
        var strictSerializer = SceneSerializer(registry: registry)
        strictSerializer.strict = true
        let world = World()
        XCTAssertThrowsError(try strictSerializer.decode(doc, into: world)) { error in
            XCTAssertEqual(error as? SceneError, .unknownComponent("Mystery"))
        }
        XCTAssertEqual(world.entityCount, 0)
    }

    // A document survives JSON serialisation and parsing without change.
    func testJSONDocumentRoundTrip() throws {
        var doc = SceneDocument(
            name: "Json",
            entities: [SceneDocument.EntityRecord(id: 0, components: ["Name": .object(["value": .string("A")])])])
        doc.metadata["author"] = .string("tests")
        let data = try doc.jsonData()
        XCTAssertEqual(try SceneDocument.load(from: data), doc)
    }

    // Input that is not valid JSON is rejected.
    func testLoadRejectsInvalidJSON() {
        XCTAssertThrowsError(try SceneDocument.load(from: Data("not json".utf8)))
    }
}

final class SceneDocumentValidationTests: XCTestCase {
    // A document with a format version newer than this engine understands is rejected.
    func testRejectsUnsupportedVersion() throws {
        var doc = SceneDocument(name: "Future", entities: [])
        doc.formatVersion = SceneDocument.currentVersion + 1
        let data = try doc.jsonData()
        XCTAssertThrowsError(try SceneDocument.load(from: data)) { error in
            XCTAssertEqual(error as? SceneError, .unsupportedVersion(SceneDocument.currentVersion + 1))
        }
    }

    // Two entity records with the same id are rejected.
    func testRejectsDuplicateIDs() throws {
        let doc = SceneDocument(
            name: "Dup", entities: [SceneDocument.EntityRecord(id: 4), SceneDocument.EntityRecord(id: 4)])
        XCTAssertThrowsError(try SceneDocument.load(from: try doc.jsonData())) { error in
            XCTAssertEqual(error as? SceneError, .duplicateID(4))
        }
    }

    // A parent id that does not exist in the document is rejected.
    func testRejectsDanglingParent() throws {
        let doc = SceneDocument(name: "Dangling", entities: [SceneDocument.EntityRecord(id: 0, parent: 9)])
        XCTAssertThrowsError(try SceneDocument.load(from: try doc.jsonData())) { error in
            XCTAssertEqual(error as? SceneError, .invalidParent(entity: 0, parent: 9))
        }
    }

    // Two entities that are each other's parent form a cycle, which is rejected.
    func testRejectsParentCycle() throws {
        let doc = SceneDocument(
            name: "Cycle",
            entities: [SceneDocument.EntityRecord(id: 0, parent: 1), SceneDocument.EntityRecord(id: 1, parent: 0)])
        XCTAssertThrowsError(try SceneDocument.load(from: try doc.jsonData())) { error in
            assertMalformed(error)
        }
    }

    // An entity that is its own parent is rejected as a cycle.
    func testRejectsSelfParent() throws {
        let doc = SceneDocument(name: "Self", entities: [SceneDocument.EntityRecord(id: 0, parent: 0)])
        XCTAssertThrowsError(try SceneDocument.load(from: try doc.jsonData())) { error in
            assertMalformed(error)
        }
    }

    // Documents larger than the configured byte limit are rejected before parsing.
    func testRejectsOversizedDocument() throws {
        let doc = SceneDocument(name: "Big", entities: [])
        let data = try doc.jsonData()
        XCTAssertThrowsError(try SceneDocument.load(from: data, limits: DecodeLimits(maxFileBytes: 10))) { error in
            assertMalformed(error)
        }
    }

    // Component payloads nested deeper than the configured limit are rejected.
    func testRejectsExcessivelyNestedComponent() throws {
        let deep: JSONValue = .object(["a": .object(["b": .object(["c": .null])])])
        let doc = SceneDocument(
            name: "Deep", entities: [SceneDocument.EntityRecord(id: 0, components: ["Deep": deep])])
        XCTAssertThrowsError(
            try SceneDocument.load(from: try doc.jsonData(), limits: DecodeLimits(maxNestingDepth: 2))
        ) { error in
            assertMalformed(error)
        }
    }

    // A well-formed document with a valid parent chain is accepted.
    func testAcceptsValidParentChain() throws {
        let doc = SceneDocument(
            name: "Chain",
            entities: [
                SceneDocument.EntityRecord(id: 0),
                SceneDocument.EntityRecord(id: 1, parent: 0),
                SceneDocument.EntityRecord(id: 2, parent: 1),
            ])
        XCTAssertNoThrow(try SceneDocument.load(from: try doc.jsonData()))
    }
}

final class RenderComponentDecodingTests: XCTestCase {
    /// Skinned renderers saved before the shadow flags existed load with both flags on.
    func testSkinnedMeshRendererDecodesWithoutShadowFlags() throws {
        var renderer = SkinnedMeshRenderer(mesh: AssetID("m"), materials: [AssetID("mat")], skin: AssetID("s"))
        renderer.castsShadows = false
        renderer.receivesShadows = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(renderer)) as? [String: Any])
        json.removeValue(forKey: "castsShadows")
        json.removeValue(forKey: "receivesShadows")
        json.removeValue(forKey: "joints")
        let decoded = try JSONDecoder().decode(SkinnedMeshRenderer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.mesh, AssetID("m"))
        XCTAssertEqual(decoded.skin, AssetID("s"))
        XCTAssertTrue(decoded.joints.isEmpty)
        XCTAssertTrue(decoded.castsShadows)
        XCTAssertTrue(decoded.receivesShadows)
    }

    /// The shadow flags survive a round trip when present.
    func testSkinnedMeshRendererRoundTripKeepsShadowFlags() throws {
        var renderer = SkinnedMeshRenderer(mesh: AssetID("m"), materials: [], skin: AssetID("s"))
        renderer.receivesShadows = false
        let decoded = try JSONDecoder().decode(SkinnedMeshRenderer.self, from: JSONEncoder().encode(renderer))
        XCTAssertEqual(decoded, renderer)
    }
}
