#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaDigest

/// The payload an install carries, read once from start to end, every byte hashed as it is read.
public final class InstallPayloadReader {
    private let descriptor: Int32
    /// The payload's file, for messages.
    public let path: String
    private var offset: off_t = 0
    private var hasher = SHA256()
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)

    init(_ descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// The payload's next bytes; nil at its end.
    public func next() throws(Installer.Failure) -> ArraySlice<UInt8>? {
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .system(operation: "read", path: path, errno: errno) }
            guard count > 0 else { return nil }
            offset += off_t(count)
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            return buffer[0..<count]
        }
    }

    /// The SHA-256 of the whole payload, reading whatever the lander left.
    func finish() throws(Installer.Failure) -> [UInt8] {
        while try next() != nil {}
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
