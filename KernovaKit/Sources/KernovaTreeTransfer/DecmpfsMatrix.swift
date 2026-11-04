#if canImport(Darwin)
import Darwin
#endif
import KernovaFileTree

/// The decmpfs compression types each Darwin kernel reads back, which decide the types a destination lands
/// compressed.
///
/// The closed AppleFSCompression project registers the decoders, so no source says which kernel reads which
/// type: each row is a kernel measured by building a file of each type and reading it back. Every kernel
/// without a row reads none, so a pull landing there accepts no type and every file arrives plain.
public enum DecmpfsMatrix {
    /// A Darwin kernel's release, as `uname -r` reports it, to its minor version.
    public struct Kernel: Hashable, Sendable {
        /// The major version: 27 for macOS 27.
        public let major: Int
        /// The minor version.
        public let minor: Int

        /// The kernel `major`.`minor`.
        public init(major: Int, minor: Int) {
            self.major = major
            self.minor = minor
        }

        /// The kernel `release` names, `"27.2.0"` for 27.2; nil when it does not start with two numbers.
        public init?(release: String) {
            let parts = release.split(separator: ".", maxSplits: 2)
            guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
            self.init(major: major, minor: minor)
        }
    }

    /// The measured rows. macOS 27.2 (26B123, kernel 27.2): types 3, 4, 7–9 and 11–16 read back, and type 10
    /// read back nothing in every layout tried (docs/research/2026-10-26-decmpfs-pass-through-costs.md,
    /// finding 6).
    static let rows: [Kernel: Set<UInt32>] = [
        Kernel(major: 27, minor: 2): [3, 4, 7, 8, 9, 11, 12, 13, 14, 15, 16]
    ]

    /// The types `kernel` reads back: its row, or none for a kernel without one.
    public static func types(for kernel: Kernel?) -> Set<UInt32> {
        kernel.flatMap { rows[$0] } ?? []
    }

    /// The Darwin kernel this process runs on; nil on any other OS.
    public static let runningKernel: Kernel? = {
        #if canImport(Darwin)
        var name = utsname()
        guard uname(&name) == 0 else { return nil }
        let release = withUnsafeBytes(of: name.release) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Kernel(release: release)
        #else
        return nil
        #endif
    }()

    /// The decmpfs types a pull landing on `directory`'s volume accepts, its `decmpfs_types`: those `kernel`
    /// reads back, when the volume holding `directory` stores compressed files, and none otherwise.
    ///
    /// - Parameters:
    ///   - directory: An open descriptor on the destination's volume: a directory, or a file landing there.
    ///   - fileSystem: The calls that ask the volume.
    ///   - kernel: The kernel that will read what lands.
    /// - Returns: The types, empty when none lands compressed.
    /// - Throws: `TreeFileSystemError` when the volume cannot be asked.
    public static func acceptedTypes<FileSystem: MutableTreeFileSystem>(
        landingIn directory: Int32, on fileSystem: FileSystem, kernel: Kernel? = runningKernel
    ) throws(TreeFileSystemError) -> Set<UInt32> {
        let types = types(for: kernel)
        guard !types.isEmpty, try fileSystem.volumeStoresCompressedFiles(directory) else { return [] }
        return types
    }
}
