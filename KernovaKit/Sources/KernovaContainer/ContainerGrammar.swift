#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// A container's records as the `TreeEvent`s they stand for, held to `TreeEventSequence`: one enforcement
/// path, which the encoder runs as it writes and the decoder as it reads, so neither side can produce what the
/// other refuses.
///
/// Records carry no leave, resource-fork start or finish: a header's depth stands for the leaves before it,
/// and a file's declared sizes for the rest. Each is admitted when the next record needs it, unless the
/// encoder's producer gave it first. What the grammar adds of its own concerns records alone: an LZ4 chunk
/// only in an entry whose storage is LZ4, and an end record whose counts are the sequence's.
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

    private(set) var sequence: TreeEventSequence

    init(acceptance: ContainerAcceptance) {
        sequence = TreeEventSequence(accepting: acceptance)
    }

    var ended: Bool { sequence.isEnded }
    var counted: ContainerError.Counts { sequence.counts }
    /// Whether the open file's storage is LZ4, so its chunks may be LZ4 blocks.
    var currentIsLZ4: Bool { sequence.openFile?.entry.isLZ4 ?? false }

    /// Admits `header`, returning how many directories to leave before it and what it is.
    mutating func admit(_ header: EntryHeader) throws(ContainerError) -> (leaving: Int, entry: Entry) {
        try finishWholeFile()
        let leaving = max(0, sequence.enteredDirectories - Int(header.depth))
        for _ in 0..<leaving { try sequence.admit(.leaveDirectory) }
        switch header.type {
        case .directory:
            try sequence.admit(.enterDirectory(header))
            return (leaving, .directory)
        case .symlink:
            try sequence.admit(.symlink(header))
            return (leaving, .symlink)
        default:
            try sequence.admit(.beginFile(header))
            return (leaving, .file(progress))
        }
    }

    /// Admits a chunk carrying `count` bytes of the open file's data, or of its resource fork once the data is
    /// whole, returning where the file's bytes then stand.
    mutating func admitChunk(count: UInt64, lz4: Bool) throws(ContainerError) -> Progress {
        try prepareForContent()
        if lz4, let file = sequence.openFile, !file.entry.isLZ4 { throw .lz4ChunkOutsideLZ4Storage }
        _ = try sequence.admitContent(count)
        return progress
    }

    /// Admits a step the encoder's producer gave: a leave, a resource fork's start, or a file's finish.
    mutating func admitStep(_ event: TreeEvent) throws(ContainerError) {
        if case .leaveDirectory = event { try finishWholeFile() }
        try sequence.admit(event)
    }

    /// Admits the end record, returning how many directories to leave before the end.
    mutating func admitEnd(_ end: EndRecord) throws(ContainerError) -> Int {
        try finishWholeFile()
        let leaving = sequence.enteredDirectories
        for _ in 0..<leaving { try sequence.admit(.leaveDirectory) }
        guard end.unknownFields.data.isEmpty else { throw .unknownFields }
        try sequence.admit(.end)
        let stated = ContainerError.Counts(entries: end.entries, bytes: end.bytes)
        guard stated == sequence.counts else { throw .endCountsMismatch(stated: stated, counted: sequence.counts) }
        return leaving
    }

    /// Where the open file's bytes stand.
    private var progress: Progress {
        guard let file = sequence.openFile, file.remaining == 0 else { return .continuing }
        return file.resourceForkFollows ? .resourceForkFollows : .complete
    }

    /// Admits the finish of an open file that has all its bytes, which a record after it stands for.
    private mutating func finishWholeFile() throws(ContainerError) {
        if sequence.openFile?.isWhole == true { try sequence.admit(.finishFile) }
    }

    /// Admits what a chunk stands for before it: the start of a resource fork whose data is whole, or the
    /// finish of a file with all its bytes.
    private mutating func prepareForContent() throws(ContainerError) {
        if sequence.openFile?.resourceForkFollows == true {
            try sequence.admit(.resourceFork)
        } else {
            try finishWholeFile()
        }
    }
}
