import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A persisted filename that is safe to resolve as exactly one child of an owned directory.
/// Validation is intentionally platform-independent: both POSIX and Windows separators are
/// rejected so a store written on one platform cannot become traversal syntax on another.
public struct SafeFileComponent: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidComponent(String)
        case escapedBase(String)
        case unsafeDirectory(String)
        case unsafeFileObject(String)
        case duplicateOwnership(String)
        case duplicateJobID(String)
    }

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue != ".", rawValue != "..",
              !rawValue.contains("/"), !rawValue.contains("\\") else {
            throw ValidationError.invalidComponent(rawValue)
        }
        self.rawValue = rawValue
    }

    /// Resolves the component against a standardized base and verifies the standardized
    /// candidate's parent is exactly that base before returning it.
    public func url(in base: URL) throws -> URL {
        let standardizedBase = base.standardizedFileURL
        let candidate = standardizedBase.appendingPathComponent(rawValue).standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == standardizedBase else {
            throw ValidationError.escapedBase(rawValue)
        }
        return candidate
    }

    /// Resolves a part-file component and verifies both filesystem objects without following a
    /// symbolic link. Part files may be absent (the downloader will create them) or regular files;
    /// directories, device nodes, and symbolic links are rejected before any read/write/delete.
    public func regularFileURL(in base: URL) throws -> URL {
        try Self.validateDirectory(base, allowMissing: false)
        let candidate = try url(in: base)
        if let type = try Self.objectTypeIfPresent(at: candidate), type != .typeRegular {
            throw ValidationError.unsafeFileObject(rawValue)
        }
        return candidate
    }

    /// Validates the directory entry itself (not its resolved target). Ancestor aliases such as
    /// macOS's `/var` → `/private/var` are harmless and remain supported; a caller-supplied base
    /// whose terminal entry is a symbolic link is not an owned directory and is rejected.
    public static func validateDirectory(_ directory: URL, allowMissing: Bool) throws {
        guard let type = try objectTypeIfPresent(at: directory) else {
            if allowMissing { return }
            throw ValidationError.unsafeDirectory(directory.path)
        }
        guard type == .typeDirectory else {
            throw ValidationError.unsafeDirectory(directory.path)
        }
    }

    /// Removes one child discovered by directly enumerating an owned directory. Unlike persisted
    /// filenames, an already-enumerated POSIX name may contain `\`. The terminal entry must be a
    /// regular file or symbolic link; `unlink` removes a link itself and never follows its target.
    /// Directories and special filesystem objects are retained and reported as unsafe.
    @discardableResult
    public static func removeEnumeratedRegularFileOrSymbolicLink(
        named name: String,
        from directory: URL
    ) throws -> Bool {
        try validateDirectory(directory, allowMissing: false)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ValidationError.invalidComponent(name)
        }

        let standardizedDirectory = directory.standardizedFileURL
        let candidate = standardizedDirectory.appendingPathComponent(name).standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == standardizedDirectory else {
            throw ValidationError.escapedBase(name)
        }
        guard let type = try objectTypeIfPresent(at: candidate) else { return false }
        guard type == .typeRegular || type == .typeSymbolicLink else {
            throw ValidationError.unsafeFileObject(name)
        }

        let result: Int32 = candidate.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return true
    }

    /// Case- and canonical-Unicode-insensitive identity used for exclusive part ownership. This
    /// is intentionally conservative so a store remains safe when moved between filesystems with
    /// different case/normalization behavior.
    var ownershipKey: String {
        rawValue
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func objectTypeIfPresent(at url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type]
                as? FileAttributeType
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
