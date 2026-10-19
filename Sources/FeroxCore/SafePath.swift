import Foundation

/// Errors raised when validating external paths.
public enum PathError: Error, Equatable, CustomStringConvertible {
    case empty
    case absoluteNotAllowed(String)
    case escapesRoot(String)
    case invalidCharacters(String)
    case tooLong(Int)

    public var description: String {
        switch self {
        case .empty: return "Path is empty"
        case .absoluteNotAllowed(let p): return "Absolute paths are not allowed here: \(p)"
        case .escapesRoot(let p): return "Path escapes the project root: \(p)"
        case .invalidCharacters(let p): return "Path contains control or NUL characters: \(p)"
        case .tooLong(let n): return "Path is too long (\(n) bytes)"
        }
    }
}

/// Validates paths that come from untrusted data (scene files, glTF `uri` fields,
/// network messages, mod content) so they cannot read outside an allowed root.
///
/// Validation is lexical and also resolves symbolic links when the target exists, so a
/// symlink inside the project pointing elsewhere is rejected as well.
public struct SafePath: Sendable {
    /// Absolute path of the allowed root. Stored as `String` because `URL` is not `Sendable`
    /// on the Swift 5.10 Linux SDK, and that warning is an error on the floor CI job.
    private let rootPath: String
    public var root: URL { URL(fileURLWithPath: rootPath) }
    public static let maxLength = 4096

    public init(root: URL) {
        rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Resolves `relative` against the root, rejecting traversal, absolute paths and
    /// control characters. Returns the resolved file URL.
    public func resolve(_ relative: String) throws -> URL {
        guard !relative.isEmpty else { throw PathError.empty }
        guard relative.utf8.count <= SafePath.maxLength else { throw PathError.tooLong(relative.utf8.count) }
        if relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw PathError.invalidCharacters(relative)
        }
        if relative.hasPrefix("/") || relative.hasPrefix("~") || relative.contains("://") {
            throw PathError.absoluteNotAllowed(relative)
        }
        // Lexical normalisation: reject any component that would climb above the root.
        var depth = 0
        for comp in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                depth -= 1
                if depth < 0 { throw PathError.escapesRoot(relative) }
            } else {
                depth += 1
            }
        }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath() : url
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
            throw PathError.escapesRoot(relative)
        }
        return resolved
    }

    /// Makes `url` relative to the root, if it lies inside it.
    public func relativePath(for url: URL) -> String? {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard p.hasPrefix(rootPath) else { return nil }
        return String(p.dropFirst(rootPath.count))
    }
}

/// Bounds applied when decoding untrusted binary or JSON data.
public struct DecodeLimits: Sendable, Hashable {
    public var maxFileBytes: Int
    public var maxElementCount: Int
    public var maxTextureDimension: Int
    public var maxNestingDepth: Int

    public init(
        maxFileBytes: Int = 512 << 20, maxElementCount: Int = 50_000_000, maxTextureDimension: Int = 16384,
        maxNestingDepth: Int = 128
    ) {
        self.maxFileBytes = maxFileBytes
        self.maxElementCount = maxElementCount
        self.maxTextureDimension = maxTextureDimension
        self.maxNestingDepth = maxNestingDepth
    }
    public static let `default` = DecodeLimits()

    /// Size of the file at `url` in bytes, or nil if it cannot be read.
    public static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// Reads a file after checking its size against `maxFileBytes`, so an oversized file is
    /// rejected before any of it is loaded. The data is memory-mapped where that is safe.
    public func readFile(at url: URL) throws -> Data {
        if let size = Self.fileSize(at: url), size > maxFileBytes {
            throw DecodeLimitError.fileTooLarge(path: url.lastPathComponent, size: size, limit: maxFileBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // The file may have grown between the size check and the read.
        guard data.count <= maxFileBytes else {
            throw DecodeLimitError.fileTooLarge(path: url.lastPathComponent, size: data.count, limit: maxFileBytes)
        }
        return data
    }
}

/// Raised by `DecodeLimits.readFile(at:)`.
public enum DecodeLimitError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge(path: String, size: Int, limit: Int)

    public var description: String {
        switch self {
        case .fileTooLarge(let path, let size, let limit): "\(path) is \(size) bytes, over the \(limit)-byte limit"
        }
    }
}
