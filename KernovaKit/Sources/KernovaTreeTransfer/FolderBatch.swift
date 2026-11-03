#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaFileTree
import KernovaSynchronization

/// A folder's symlinks and small files, held until they are created side by side relative to the folder's
/// descriptor.
///
/// Created one at a time, small files leave a tree of them several times slower than AppleArchive's extract,
/// and side by side they match it (docs/research/2026-10-24-receiver-writer-parity.md, findings 1, 2 and 10,
/// which also measured the limits).
struct FolderBatch: Sendable {
    /// The largest file a batch takes.
    static let largestFile: UInt64 = 256 * 1024
    /// The most file bytes and link targets one batch holds.
    static let byteBudget = 8 * 1024 * 1024
    /// The most entries one batch holds.
    static let entryBudget = 256

    /// An entry waiting to be created: everything creating it takes.
    struct Entry: Sendable {
        enum Content: Sendable {
            case file([FilePiece])
            case symlink(target: [UInt8])
        }

        let name: [UInt8]
        let path: [[UInt8]]
        let metadata: EntryMetadata
        let content: Content
        let byteCount: Int
    }

    /// One run of a held file's bytes.
    enum FilePiece: Sendable {
        case bytes(Data)
        case zeros(Int64)
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
    ) -> (position: Int, failure: TreeFileSystemError)? {
        let outcomes = Locked([Int: Result<Identity, TreeFileSystemError>]())
        DispatchQueue.concurrentPerform(iterations: entries.count) { position in
            let outcome = Result { () throws(TreeFileSystemError) in
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

    private static func create<FileSystem: MutableTreeFileSystem>(
        _ entry: Entry, in directory: Int32, holeSize: Int?, on fileSystem: FileSystem
    ) throws(TreeFileSystemError) -> Identity {
        switch entry.content {
        case .file(let pieces):
            let descriptor = try fileSystem.createFile(entry.name, in: directory)
            let identity: Identity
            do {
                var file = SparseFile(fileSystem: fileSystem, descriptor: descriptor, holeSize: holeSize)
                for piece in pieces {
                    switch piece {
                    case .bytes(let bytes):
                        try file.append(bytes)
                    case .zeros(let count):
                        try file.appendZeros(count)
                    }
                }
                try file.finish()
                try entry.metadata.apply(to: .descriptor(descriptor), on: fileSystem)
                identity = Identity(try fileSystem.status(of: descriptor))
            } catch {
                fileSystem.close(descriptor)
                throw error
            }
            try fileSystem.closeWritten(descriptor)
            return identity
        case .symlink(let target):
            try fileSystem.makeSymlink(entry.name, to: target, in: directory)
            let identity = Identity(try fileSystem.status(of: entry.name, in: directory))
            try entry.metadata.apply(to: .symlink(entry.name, in: directory), on: fileSystem)
            return identity
        }
    }

    /// The failure creating `entries` one at a time, in order, would have met first, given the `outcomes`
    /// of creating them side by side.
    ///
    /// Of two entries the volume takes for one name, the later in order fails one at a time, but either can
    /// side by side; a failed entry whose name now holds another entry's creation collided with it, so each
    /// collision is charged to the second, in order, of the entries that took the name.
    private static func firstFailure<FileSystem: MutableTreeFileSystem>(
        of entries: [Entry], outcomes: [Int: Result<Identity, TreeFileSystemError>], in directory: Int32,
        on fileSystem: FileSystem
    ) -> (position: Int, failure: TreeFileSystemError)? {
        var charged: [Int: TreeFileSystemError] = [:]
        var holders: [Identity: Int] = [:]
        for (position, outcome) in outcomes {
            switch outcome {
            case .success(let identity): holders[identity] = position
            case .failure(let failure): charged[position] = failure
            }
        }
        var sharers: [Int: [Int]] = [:]
        var collision: [Int: TreeFileSystemError] = [:]
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
