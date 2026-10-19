/// Tests for FeroxCore's data-handling utilities: `SafePath` (rejecting traversal and
/// symlink escapes from untrusted paths), `JSONValue` (round trips, accessors, depth),
/// generational `HandlePool`/`Handle`, `AssetID`, and the engine version string.
import Foundation
import XCTest

@testable import FeroxCore

private enum MeshTag {}

private struct Pair: Codable, Equatable {
    var x: Int
    var name: String
}

private struct Bound: Codable, Equatable {
    var bound: Double
}

private struct Reference: Codable, Equatable {
    var id: AssetID
}

final class SafePathTests: XCTestCase {
    /// Creates a fresh directory under the system temporary directory for one test.
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeroxSafePathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // An ordinary relative path resolves to a file inside the root and maps back to the same relative path.
    func testAcceptsNormalRelativePath() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        let url = try safe.resolve("assets/mesh.bin")
        XCTAssertTrue(url.path.hasSuffix("assets/mesh.bin"))
        XCTAssertEqual(safe.relativePath(for: url), "assets/mesh.bin")
    }

    // Dot components and parent steps that stay inside the root are accepted.
    func testAcceptsDotAndInternalParentSegments() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        XCTAssertTrue(try safe.resolve("a/./b.txt").path.hasSuffix("a/b.txt"))
        XCTAssertTrue(try safe.resolve("a/../b.txt").path.hasSuffix("/b.txt"))
    }

    // Paths that climb above the root with ".." are rejected.
    func testRejectsParentTraversalOutOfRoot() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        XCTAssertThrowsError(try safe.resolve("../secret.txt")) { error in
            XCTAssertEqual(error as? PathError, .escapesRoot("../secret.txt"))
        }
        XCTAssertThrowsError(try safe.resolve("a/../../secret")) { error in
            XCTAssertEqual(error as? PathError, .escapesRoot("a/../../secret"))
        }
    }

    // Absolute paths, home-relative paths and URLs with a scheme are rejected outright.
    func testRejectsAbsoluteHomeAndSchemePaths() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        XCTAssertThrowsError(try safe.resolve("/etc/passwd")) { error in
            XCTAssertEqual(error as? PathError, .absoluteNotAllowed("/etc/passwd"))
        }
        XCTAssertThrowsError(try safe.resolve("~/notes"))
        XCTAssertThrowsError(try safe.resolve("file:///etc/passwd"))
    }

    // Empty paths and paths containing control characters are rejected.
    func testRejectsEmptyAndControlCharacterPaths() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        XCTAssertThrowsError(try safe.resolve("")) { error in
            XCTAssertEqual(error as? PathError, .empty)
        }
        XCTAssertThrowsError(try safe.resolve("bad\u{0}name")) { error in
            XCTAssertEqual(error as? PathError, .invalidCharacters("bad\u{0}name"))
        }
        XCTAssertThrowsError(try safe.resolve("tab\tname"))
    }

    // Paths longer than the maximum byte length are rejected before any filesystem access.
    func testRejectsOverlongPath() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        let long = String(repeating: "a", count: SafePath.maxLength + 1)
        XCTAssertThrowsError(try safe.resolve(long)) { error in
            XCTAssertEqual(error as? PathError, .tooLong(SafePath.maxLength + 1))
        }
    }

    // A symbolic link inside the root that points outside it is rejected once resolved.
    func testRejectsSymlinkPointingOutsideRoot() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path, withDestinationPath: outside.path)
        let safe = SafePath(root: root)
        XCTAssertThrowsError(try safe.resolve("link/secret.txt")) { error in
            XCTAssertEqual(error as? PathError, .escapesRoot("link/secret.txt"))
        }
    }

    // relativePath returns nil for a URL that lies outside the root.
    func testRelativePathOutsideRootIsNil() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let safe = SafePath(root: base)
        XCTAssertNil(safe.relativePath(for: URL(fileURLWithPath: "/usr/bin")))
    }

    // readFile rejects a file over the byte limit before reading it, and reads one within it.
    func testReadFileEnforcesSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 64).write(to: url)
        XCTAssertEqual(DecodeLimits.fileSize(at: url), 64)
        XCTAssertEqual(try DecodeLimits(maxFileBytes: 64).readFile(at: url).count, 64)
        XCTAssertThrowsError(try DecodeLimits(maxFileBytes: 63).readFile(at: url)) { error in
            XCTAssertEqual(error as? DecodeLimitError, .fileTooLarge(path: url.lastPathComponent, size: 64, limit: 63))
        }
    }

    // A missing file is reported as a read error, not as a size violation.
    func testReadFileMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-missing-\(UUID().uuidString)")
        XCTAssertNil(DecodeLimits.fileSize(at: url))
        XCTAssertThrowsError(try DecodeLimits.default.readFile(at: url)) { XCTAssertNil($0 as? DecodeLimitError) }
    }
}

final class JSONValueTests: XCTestCase {
    // A tree of mixed values survives a JSON encode and decode unchanged.
    func testJSONRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("Ferox"), "version": .number(1), "tags": .array([.bool(true), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    // A typed value converts to a JSON tree and back again.
    func testTypedEncodeAndDecode() throws {
        let tree = try JSONValue.encode(Pair(x: 3, name: "a"))
        XCTAssertEqual(tree["x"]?.intValue, 3)
        XCTAssertEqual(tree["name"]?.stringValue, "a")
        XCTAssertEqual(try tree.decode(Pair.self), Pair(x: 3, name: "a"))
    }

    // Non-finite doubles are encoded as the strings "inf" and "-inf" and decoded back to infinity.
    func testNonFiniteDoublesUseStringSentinels() throws {
        let tree = try JSONValue.encode(Bound(bound: .infinity))
        XCTAssertEqual(tree["bound"], JSONValue.string("inf"))
        XCTAssertEqual(try tree.decode(Bound.self).bound, .infinity)
    }

    // Subscripts and typed accessors return values only for the matching case.
    func testSubscriptsAndAccessorsMatchCase() {
        let obj = JSONValue.object(["a": .number(2)])
        XCTAssertEqual(obj["a"]?.intValue, 2)
        XCTAssertNil(obj["missing"])
        XCTAssertNil(JSONValue.array([.string("x")])[5])
        XCTAssertEqual(JSONValue.array([.string("x")])[0]?.stringValue, "x")
        XCTAssertEqual(JSONValue.number(2).doubleValue, 2)
        XCTAssertNil(JSONValue.string("s").doubleValue)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
    }

    // intValue is nil for non-finite numbers rather than trapping.
    func testIntValueRejectsNonFinite() {
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
    }

    // depth counts container nesting, with scalars at depth zero.
    func testDepthCountsNesting() {
        XCTAssertEqual(JSONValue.number(1).depth, 0)
        XCTAssertEqual(JSONValue.array([]).depth, 1)
        XCTAssertEqual(JSONValue.array([.array([])]).depth, 2)
        XCTAssertEqual(JSONValue.object(["a": .object(["b": .null])]).depth, 2)
    }
}

final class HandlePoolTests: XCTestCase {
    // An inserted value is retrievable through its handle and counted in the pool.
    func testInsertAndLookup() {
        var pool = HandlePool<MeshTag, String>()
        let h = pool.insert("cube")
        XCTAssertEqual(pool[h], "cube")
        XCTAssertTrue(pool.contains(h))
        XCTAssertEqual(pool.count, 1)
    }

    // After removal the old handle is stale, and a new value reusing the slot does not alias it.
    func testStaleHandleDoesNotAliasReusedSlot() {
        var pool = HandlePool<MeshTag, String>()
        let old = pool.insert("cube")
        XCTAssertEqual(pool.remove(old), "cube")
        let new = pool.insert("sphere")
        XCTAssertEqual(new.index, old.index)
        XCTAssertNotEqual(new.generation, old.generation)
        XCTAssertNil(pool[old])
        XCTAssertEqual(pool[new], "sphere")
    }

    // The invalid handle is never contained in a pool.
    func testInvalidHandleIsNotContained() {
        var pool = HandlePool<MeshTag, String>()
        _ = pool.insert("cube")
        let invalid = Handle<MeshTag>.invalid
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(pool[invalid])
        XCTAssertFalse(pool.contains(invalid))
    }

    // Assigning through the subscript updates the value, and assigning nil removes it.
    func testSubscriptSetAndClear() {
        var pool = HandlePool<MeshTag, String>()
        let h = pool.insert("cube")
        pool[h] = "updated"
        XCTAssertEqual(pool[h], "updated")
        pool[h] = nil
        XCTAssertNil(pool[h])
        XCTAssertEqual(pool.count, 0)
    }

    // forEach visits only live values, in slot order.
    func testForEachVisitsLiveValues() {
        var pool = HandlePool<MeshTag, String>()
        _ = pool.insert("a")
        let b = pool.insert("b")
        _ = pool.insert("c")
        pool.remove(b)
        var seen: [String] = []
        // swift-format-ignore: ReplaceForEachWithForLoop
        pool.forEach { _, value in seen.append(value) }
        XCTAssertEqual(seen, ["a", "c"])
    }

    // removeAll invalidates every outstanding handle.
    func testRemoveAllInvalidatesHandles() {
        var pool = HandlePool<MeshTag, String>()
        let h = pool.insert("cube")
        pool.removeAll()
        XCTAssertEqual(pool.count, 0)
        XCTAssertFalse(pool.contains(h))
    }
}

final class AssetIDTests: XCTestCase {
    // A path-derived ID is deterministic, distinct for different paths, and carries the "path-" prefix.
    func testDerivedIDIsDeterministic() {
        let a = AssetID.derived(fromPath: "textures/rock.png")
        XCTAssertEqual(a, AssetID.derived(fromPath: "textures/rock.png"))
        XCTAssertNotEqual(a, AssetID.derived(fromPath: "textures/tree.png"))
        XCTAssertTrue(a.rawValue.hasPrefix("path-"))
    }

    // Generated IDs are unique, and the empty ID reports as none.
    func testGeneratedIDsAreUniqueAndNoneIsEmpty() {
        XCTAssertNotEqual(AssetID(), AssetID())
        XCTAssertTrue(AssetID.none.isNone)
        XCTAssertFalse(AssetID("abc").isNone)
    }

    // An AssetID is stored as a bare string inside its containing JSON object.
    func testCodableStoresBareString() throws {
        let data = try JSONEncoder().encode(Reference(id: AssetID("abc")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"id\":\"abc\"}")
        XCTAssertEqual(try JSONDecoder().decode(Reference.self, from: data), Reference(id: AssetID("abc")))
    }

    // IDs order by their raw string value.
    func testOrderingFollowsRawValue() {
        XCTAssertLessThan(AssetID("a"), AssetID("b"))
    }
}

final class FeroxVersionTests: XCTestCase {
    // The version string is the dotted major, minor and patch numbers.
    func testVersionString() {
        XCTAssertEqual(FeroxVersion.string, "0.1.0")
        XCTAssertEqual(FeroxVersion.major, 0)
        XCTAssertEqual(FeroxVersion.minor, 1)
        XCTAssertEqual(FeroxVersion.patch, 0)
    }
}
