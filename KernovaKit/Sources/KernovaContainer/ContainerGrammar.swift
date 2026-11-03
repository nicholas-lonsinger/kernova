#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// The rules a container's records keep, past their framing: one enforcement path, which the encoder runs as
/// it writes and the decoder as it reads, so neither side can produce what the other refuses.
struct ContainerGrammar {
    /// What an admitted header is.
    enum Entry {
        case directory
        /// A file or INLINE data, and how far its bytes already are: complete when it carries none, at its
        /// resource fork when it carries only a fork.
        case file(Progress)
        case symlink
    }

    /// Where a file's bytes stand after a header or chunk.
    enum Progress: Equatable {
        /// More bytes of the same part follow.
        case continuing
        /// The data has all its bytes and the resource fork's follow.
        case resourceForkFollows
        /// The file has all its bytes.
        case complete
    }

    /// The bytes the current entry still owes: its data's, then its resource fork's.
    struct Owed: Equatable {
        var data: UInt64
        var resourceFork: UInt64

        /// What the next chunk counts against: the data until it is whole, then the fork.
        var current: UInt64 { data > 0 ? data : resourceFork }
        var total: UInt64 { data &+ resourceFork }
    }

    let acceptance: ContainerAcceptance

    /// The directories entered and not yet left; an entry at depth d lies inside the first d of them.
    private(set) var enteredDirectories = 0
    /// The bytes the current entry still owes, or nil when no entry owes any.
    private(set) var owed: Owed?
    /// Whether the current entry's storage is LZ4, so its chunks may be LZ4 blocks.
    private(set) var currentIsLZ4 = false
    private(set) var counted = ContainerError.Counts(entries: 0, bytes: 0)
    /// The logical bytes the entries so far land, which the byte ceiling bounds.
    private var landedBytes: UInt64 = 0
    private(set) var ended = false

    init(acceptance: ContainerAcceptance) {
        self.acceptance = acceptance
    }

    /// Admits `header`, returning how many directories to leave before it and what it is.
    mutating func admit(_ header: EntryHeader) throws(ContainerError) -> (leaving: Int, entry: Entry) {
        try requireBetweenEntries()
        let leaving = try place(header)
        let entry = try ValidatedEntry(header)
        if entry.isLZ4 && !acceptance.acceptsLZ4 { throw .lz4NotAccepted }
        landedBytes = try acceptance.admitLanding(entry, after: landedBytes)
        counted.entries += 1
        enteredDirectories = Int(header.depth)
        switch header.type {
        case .directory:
            enteredDirectories += 1
            return (leaving, .directory)
        case .symlink:
            return (leaving, .symlink)
        default:
            currentIsLZ4 = entry.isLZ4
            let owing = Owed(data: entry.dataByteCount, resourceFork: entry.resourceForkByteCount)
            owed = owing.total == 0 ? nil : owing
            return (leaving, .file(Self.progress(owing)))
        }
    }

    /// Admits a chunk carrying `count` bytes of the current entry's data, or of its resource fork once the
    /// data is whole, returning where the entry's bytes then stand.
    mutating func admitChunk(count: UInt64, lz4: Bool) throws(ContainerError) -> Progress {
        guard !ended else { throw .bytesAfterEnd }
        guard var owing = owed else { throw .chunkOutsideEntry }
        guard !lz4 || currentIsLZ4 else { throw .lz4ChunkOutsideLZ4Storage }
        guard count > 0 else { throw .emptyChunk }
        guard count <= owing.current else { throw .chunkPastEntrySize(count: count, remaining: owing.current) }
        counted.bytes += count
        let progress: Progress
        if owing.data > 0 {
            owing.data -= count
            progress = Self.progress(owing)
        } else {
            owing.resourceFork -= count
            progress = owing.resourceFork > 0 ? .continuing : .complete
        }
        owed = owing.total == 0 ? nil : owing
        return progress
    }

    /// Admits the end record, returning how many directories to leave before the end.
    mutating func admitEnd(_ end: EndRecord) throws(ContainerError) -> Int {
        try requireBetweenEntries()
        guard end.unknownFields.data.isEmpty else { throw .unknownFields }
        guard counted.entries > 0 else { throw .noEntry }
        let stated = ContainerError.Counts(entries: end.entries, bytes: end.bytes)
        guard stated == counted else { throw .endCountsMismatch(stated: stated, counted: counted) }
        ended = true
        defer { enteredDirectories = 0 }
        return enteredDirectories
    }

    /// Where a file owing `owing` stands once its data has all its bytes.
    private static func progress(_ owing: Owed) -> Progress {
        if owing.data > 0 { return .continuing }
        return owing.resourceFork > 0 ? .resourceForkFollows : .complete
    }

    private func requireBetweenEntries() throws(ContainerError) {
        guard !ended else { throw .bytesAfterEnd }
        if let owed { throw .entryIncomplete(remaining: owed.total) }
    }

    /// The directories to leave before `header`, whose parent is then the innermost one entered.
    private func place(_ header: EntryHeader) throws(ContainerError) -> Int {
        switch header.type {
        case .data, .file, .directory, .symlink: break
        case .unspecified, .UNRECOGNIZED: throw .unknownEntryType
        }
        if counted.entries == 0 {
            guard header.depth == 0 else { throw .firstEntryNotAtRoot(depth: header.depth) }
            guard header.type == Self.rootType(of: acceptance.storage) else {
                throw .rootTypeMismatch(header.type, expected: acceptance.storage)
            }
            return 0
        }
        guard header.type != .data else { throw .dataEntryNotRoot }
        guard header.depth > 0 else { throw .secondRootEntry }
        guard Int(header.depth) <= enteredDirectories else {
            throw .depthBeyondParent(depth: header.depth, enteredDirectories: enteredDirectories)
        }
        return enteredDirectories - Int(header.depth)
    }

    /// The root entry's type a representation of `storage` sends, or nil for a storage nothing sends.
    static func rootType(of storage: Representation.Storage) -> EntryHeader.TypeEnum? {
        switch storage {
        case .inline: .data
        case .file: .file
        case .folder: .directory
        case .unspecified, .UNRECOGNIZED: nil
        }
    }
}
