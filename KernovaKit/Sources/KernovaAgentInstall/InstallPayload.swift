#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaDigest

/// Where an install's payload comes from.
public enum InstallPayloadSource: Sendable, Equatable {
    /// The file at a path, which holds the payload.
    case file(String)
    /// The directory at an absolute path, packed as it is read (``UpdatePayloadPacker``): the bytes a build
    /// packing the same tree writes, so the install records the identity that build serves.
    case packedDirectory(String)

    /// The file or directory, for messages.
    public var path: String {
        switch self {
        case .file(let path), .packedDirectory(let path): path
        }
    }
}

/// The payload an install carries, read once from start to end, every byte hashed as it is read.
public final class InstallPayloadReader {
    private let source: InstallPayloadSource
    /// The source, open: the file a ``InstallPayloadSource/file(_:)`` source reads from; a packed directory's,
    /// opened only to find it before the install changes anything.
    private let descriptor: Int32
    private var hasher = SHA256()
    private var isRead = false

    /// The payload's file or directory, for messages.
    public var path: String { source.path }

    init(_ source: InstallPayloadSource, descriptor: Int32) {
        self.source = source
        self.descriptor = descriptor
    }

    /// Hands `body` the payload's bytes in order, to its end; once per payload.
    public func read(_ body: (UnsafeRawBufferPointer) throws(Installer.Failure) -> Void) throws(Installer.Failure) {
        precondition(!isRead, "an install's payload is read once")
        isRead = true
        switch source {
        case .file: try readFile(body)
        case .packedDirectory(let directory): try pack(directory, body)
        }
    }

    private func readFile(_ body: (UnsafeRawBufferPointer) throws(Installer.Failure) -> Void) throws(Installer.Failure)
    {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 1)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, buffer.baseAddress, buffer.count, offset)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .system(operation: "read", path: path, errno: errno) }
            guard count > 0 else { return }
            offset += off_t(count)
            let piece = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            hasher.update(piece)
            try body(piece)
        }
    }

    private func pack(
        _ directory: String, _ body: (UnsafeRawBufferPointer) throws(Installer.Failure) -> Void
    ) throws(Installer.Failure) {
        // The packer's output is untyped; the lander's failure is told from the packer's own by its type.
        do {
            try withoutActuallyEscaping(body) { body in
                try UpdatePayloadPacker.pack(directoryAt: directory) { [self] data in
                    try data.withUnsafeBytes { bytes in
                        hasher.update(bytes)
                        try body(bytes)
                    }
                }
            }
        } catch let failure as Installer.Failure {
            throw failure
        } catch {
            throw .packing(path: directory, detail: String(describing: error))
        }
    }

    /// The SHA-256 of the whole payload, reading it first when the lander did not.
    func finish() throws(Installer.Failure) -> [UInt8] {
        if !isRead { try read { _ throws(Installer.Failure) in } }
        return hasher.finalize()
    }
}

/// A directory below the agent's root, open, that a lander makes the install's payload in.
public struct InstallDirectory {
    /// The directory.
    public let descriptor: Int32
    /// Its path, for messages.
    public let path: String
    /// Who everything made in it belongs to; nil for the installer.
    let owner: Installer.Owner?

    /// Writes `name` here whole, as ``Installer`` writes every file: `fill` writes a new file beside it, which
    /// then replaces it in one rename, with `mode` and belonging to the directory's owner.
    public func writeFile(
        _ name: String, mode: UInt16, _ fill: (Int32) throws(Installer.Failure) -> Void
    ) throws(Installer.Failure) {
        try Installer.writeFile(in: descriptor, name, path: path + "/" + name, mode: mode, owner: owner, fill)
    }
}
#endif
