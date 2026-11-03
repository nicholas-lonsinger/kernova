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
        /// A file or INLINE data; `complete` when it carries no bytes, so no chunk follows.
        case file(complete: Bool)
        case symlink
    }

    let acceptance: ContainerAcceptance

    /// The directories entered and not yet left; an entry at depth d lies inside the first d of them.
    private(set) var enteredDirectories = 0
    /// The bytes the current entry still owes, or nil when no entry owes any.
    private(set) var remainingBytes: UInt64?
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
        let size = try storageSize(of: header)
        _ = try ValidatedEntry(header)
        if size.landed > acceptance.byteCeiling - landedBytes {
            throw .exceedsByteCeiling(declared: landedBytes &+ size.landed, ceiling: acceptance.byteCeiling)
        }
        landedBytes += size.landed
        counted.entries += 1
        enteredDirectories = Int(header.depth)
        switch header.type {
        case .directory:
            enteredDirectories += 1
            return (leaving, .directory)
        case .symlink:
            return (leaving, .symlink)
        default:
            if case .lz4 = header.storage { currentIsLZ4 = true } else { currentIsLZ4 = false }
            remainingBytes = size.carried == 0 ? nil : size.carried
            return (leaving, .file(complete: size.carried == 0))
        }
    }

    /// Admits a chunk carrying `count` bytes of the current entry, returning whether the entry is now complete.
    mutating func admitChunk(count: UInt64, lz4: Bool) throws(ContainerError) -> Bool {
        guard !ended else { throw .bytesAfterEnd }
        guard let remaining = remainingBytes else { throw .chunkOutsideEntry }
        guard !lz4 || currentIsLZ4 else { throw .lz4ChunkOutsideLZ4Storage }
        guard count > 0 else { throw .emptyChunk }
        guard count <= remaining else { throw .chunkPastEntrySize(count: count, remaining: remaining) }
        counted.bytes += count
        remainingBytes = remaining == count ? nil : remaining - count
        return remainingBytes == nil
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

    private func requireBetweenEntries() throws(ContainerError) {
        guard !ended else { throw .bytesAfterEnd }
        if let remainingBytes { throw .entryIncomplete(remaining: remainingBytes) }
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

    /// The bytes `header`'s chunks carry and the logical bytes it lands, once its storage is checked against
    /// its type and the acceptance. A decmpfs file lands the larger of its attribute's uncompressed size and
    /// its resource fork, so neither can pass the ceiling.
    private func storageSize(of header: EntryHeader) throws(ContainerError) -> (carried: UInt64, landed: UInt64) {
        switch (header.type, header.storage) {
        case (.data, .plain(let plain)?), (.file, .plain(let plain)?):
            guard plain.unknownFields.data.isEmpty else { throw .unknownFields }
            return (plain.size, plain.size)
        case (.data, .lz4(let lz4)?), (.file, .lz4(let lz4)?):
            guard lz4.unknownFields.data.isEmpty else { throw .unknownFields }
            guard acceptance.acceptsLZ4 else { throw .lz4NotAccepted }
            return (lz4.size, lz4.size)
        case (.file, .decmpfs(let decmpfs)?):
            guard decmpfs.unknownFields.data.isEmpty else { throw .unknownFields }
            let attributeHeader: DecmpfsHeader
            do {
                attributeHeader = try DecmpfsHeader(attribute: decmpfs.attribute)
            } catch {
                throw .malformedDecmpfsAttribute(error)
            }
            guard acceptance.decmpfsTypes.contains(attributeHeader.compressionType) else {
                throw .decmpfsTypeNotAccepted(attributeHeader.compressionType)
            }
            return (decmpfs.resourceForkSize, max(decmpfs.resourceForkSize, attributeHeader.uncompressedSize))
        case (.directory, nil), (.symlink, nil):
            return (0, 0)
        default:
            throw .storageNotAllowed(header.type)
        }
    }
}
