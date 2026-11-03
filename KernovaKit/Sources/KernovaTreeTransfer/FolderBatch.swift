#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaFileTree
import KernovaSynchronization

/// A folder's symlinks and small files, compressed ones included, held until they are created side by side
/// relative to the folder's descriptor.
///
/// Created one at a time, small files leave a tree of them several times slower than AppleArchive's extract,
/// and side by side they match it (docs/research/2026-10-24-receiver-writer-parity.md, findings 1, 2 and 10,
/// which also measured the limits).
struct FolderBatch: Sendable {
    /// The largest file a batch takes, data and resource fork together.
    static let largestFile: UInt64 = 256 * 1024
    /// The most file bytes and link targets one batch holds.
    static let byteBudget = 8 * 1024 * 1024
    /// The most entries one batch holds.
    static let entryBudget = 256

    /// An entry waiting to be created: everything creating it takes.
    struct Entry: Sendable {
        enum Content: Sendable {
            /// A file's data and resource fork, in storage of their own.
            case file(Data, resourceFork: Data)
            /// A file landing compressed: its `com.apple.decmpfs` attribute and resource fork.
            case compressedFile(attribute: [UInt8], logicalSize: UInt64, resourceFork: Data)
            case symlink(target: [UInt8])
        }

        let name: [UInt8]
        let path: [[UInt8]]
        let metadata: EntryMetadata
        let content: Content
        let byteCount: Int
    }

    private(set) var entries: [Entry] = []
    private var byteCount = 0

    var isEmpty: Bool { entries.isEmpty }

    /// Whether `entry` fits beside the entries already held.
    func admits(_ entry: Entry) -> Bool {
        entries.count < Self.entryBudget && byteCount + entry.byteCount <= Self.byteBudget
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        byteCount += entry.byteCount
    }

    /// The entries held, leaving the batch empty.
    mutating func take() -> [Entry] {
        defer {
            entries.removeAll(keepingCapacity: true)
            byteCount = 0
        }
        return entries
    }

    /// Creates `entries` in `directory` side by side.
    ///
    /// - Returns: the failure creating them one at a time, in order, would have met first, and the position
    ///   of the entry it names; `nil` when every entry was created.
    static func create<FileSystem: MutableTreeFileSystem>(
        _ entries: [Entry], in directory: Int32, holeSize: Int?, on fileSystem: FileSystem
    ) -> (position: Int, failure: CompressedFileFailure)? {
        let outcomes = Locked([Int: Result<Identity, CompressedFileFailure>]())
        DispatchQueue.concurrentPerform(iterations: entries.count) { position in
            let outcome = Result { () throws(CompressedFileFailure) in
                try create(entries[position], in: directory, holeSize: holeSize, on: fileSystem)
            }
            outcomes.withLock { $0[position] = outcome }
        }
        return firstFailure(of: entries, outcomes: outcomes.withLock { $0 }, in: directory, on: fileSystem)
    }

    /// A created entry's identity on its volume.
    struct Identity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: FileStatus) {
            device = status.device
            inode = status.inode
        }
    }

    /// Creates `entry` in `directory`, a failure of the calls that create a compressed file, or any other,
    /// carrying what the caller acts on.
    private static func create<FileSystem: MutableTreeFileSystem>(
        _ entry: Entry, in directory: Int32, holeSize: Int?, on fileSystem: FileSystem
    ) throws(CompressedFileFailure) -> Identity {
        switch entry.content {
        case .file(let bytes, let resourceFork):
            do {
                return try createFile(
                    entry, bytes: bytes, resourceFork: resourceFork, in: directory, holeSize: holeSize, on: fileSystem)
            } catch {
                throw .system(error)
            }
        case .compressedFile(let attribute, let logicalSize, let resourceFork):
            let file: CompressedFile<FileSystem>
            do {
                file = try CompressedFile(
                    creating: entry.name, in: directory, attribute: attribute, logicalSize: logicalSize,
                    extendedAttributes: entry.metadata.extendedAttributes, on: fileSystem)
            } catch {
                throw .system(error)
            }
            try resourceFork.withUnsafeBytes { buffer throws(CompressedFileFailure) in
                try file.appendResourceFork(buffer)
            }
            return Identity(try file.finish(entry.metadata.attributes))
        case .symlink(let target):
            do {
                try fileSystem.makeSymlink(entry.name, to: target, in: directory)
                let identity = Identity(try fileSystem.status(of: entry.name, in: directory))
                try entry.metadata.apply(to: .symlink(entry.name, in: directory), on: fileSystem)
                return identity
            } catch {
                throw .system(error)
            }
        }
    }

    private static func createFile<FileSystem: MutableTreeFileSystem>(
        _ entry: Entry, bytes: Data, resourceFork: Data, in directory: Int32, holeSize: Int?, on fileSystem: FileSystem
    ) throws(TreeFileSystemError) -> Identity {
        let descriptor = try fileSystem.createFile(entry.name, in: directory)
        let identity: Identity
        do {
            var file = SparseFile(fileSystem: fileSystem, descriptor: descriptor, holeSize: holeSize)
            try file.append(bytes)
            try file.finish()
            if !resourceFork.isEmpty {
                // A volume that holds no resource fork leaves it out, as it does any attribute it cannot hold.
                _ = try resourceFork.withUnsafeBytes { buffer throws(TreeFileSystemError) in
                    try fileSystem.writeResourceFork(descriptor, from: buffer, at: 0)
                }
            }
            try entry.metadata.apply(to: .descriptor(descriptor), on: fileSystem)
            identity = Identity(try fileSystem.status(of: descriptor))
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
        try fileSystem.closeWritten(descriptor)
        return identity
    }

    /// The failure creating `entries` one at a time, in order, would have met first, given the `outcomes`
    /// of creating them side by side.
    ///
    /// Of two entries the volume takes for one name, the later in order fails one at a time, but either can
    /// side by side; a failed entry whose name now holds another entry's creation collided with it, so each
    /// collision is charged to the second, in order, of the entries that took the name.
    private static func firstFailure<FileSystem: MutableTreeFileSystem>(
        of entries: [Entry], outcomes: [Int: Result<Identity, CompressedFileFailure>], in directory: Int32,
        on fileSystem: FileSystem
    ) -> (position: Int, failure: CompressedFileFailure)? {
        var charged: [Int: CompressedFileFailure] = [:]
        var holders: [Identity: Int] = [:]
        for (position, outcome) in outcomes {
            switch outcome {
            case .success(let identity): holders[identity] = position
            case .failure(let failure): charged[position] = failure
            }
        }
        var sharers: [Int: [Int]] = [:]
        var collision: [Int: CompressedFileFailure] = [:]
        for (position, failure) in charged {
            guard let status = try? fileSystem.status(of: entries[position].name, in: directory),
                let holder = holders[Identity(status)]
            else { continue }
            sharers[holder, default: [holder]].append(position)
            collision[holder] = failure
            charged[position] = nil
        }
        for (holder, positions) in sharers {
            if let failure = collision[holder] { charged[positions.sorted()[1]] = failure }
        }
        return charged.min { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
