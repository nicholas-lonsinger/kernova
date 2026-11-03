#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The rules a stream of `TreeEvent`s keeps, whichever format produced it and whoever consumes it: one root
/// entry of the type the pull names; each entry at the depth of the directories entered, each directory left
/// once; a file's data, then — after `resourceFork` — its resource fork, each exactly the size its header
/// declares, then `finishFile`; every header held to `ValidatedEntry` and to what the pull accepts; and `end`
/// last, once everything is left.
///
/// The container grammar admits each record's events through one, so the encoder and decoder keep these
/// rules, and a tree writer admits every event through one before it acts, so any other producer keeps them
/// too. Each event is admitted before the next; after a refusal, discard it.
public struct TreeEventSequence: Sendable {
    /// Which part of a file its bytes are.
    public enum FilePart: Sendable, Equatable {
        case data
        case resourceFork
    }

    /// The file whose bytes are arriving.
    public struct OpenFile: Sendable {
        /// Its header.
        public let entry: ValidatedEntry
        /// The part its bytes now count against.
        public fileprivate(set) var part: FilePart = .data
        /// The bytes that part still owes.
        public fileprivate(set) var remaining: UInt64

        /// The bytes still owed, the resource fork's included while the data's are arriving.
        public var owed: UInt64 {
            guard part == .data else { return remaining }
            let (sum, overflow) = remaining.addingReportingOverflow(entry.resourceForkByteCount)
            return overflow ? .max : sum
        }

        /// Whether the data has all its bytes and the resource fork's are next.
        public var resourceForkFollows: Bool {
            part == .data && remaining == 0 && entry.resourceForkByteCount > 0
        }

        /// Whether every byte has arrived, so `finishFile` is next.
        public var isWhole: Bool { owed == 0 }
    }

    /// What an admitted event asks of its consumer.
    public enum Admitted: Sendable {
        /// An entry's header, keeping every rule.
        case entry(ValidatedEntry)
        /// Bytes of the open file's `part`, starting `offset` bytes into it.
        case content(FilePart, offset: UInt64)
        /// A step that carries nothing to land: a leave, the start of a resource fork, a file's finish, the end.
        case step
    }

    /// What the pull accepts.
    public let acceptance: ContainerAcceptance
    /// The directories entered and not yet left.
    public private(set) var enteredDirectories = 0
    /// The file whose bytes are arriving, from its `beginFile` to its `finishFile`.
    public private(set) var openFile: OpenFile?
    /// The entries admitted, and the bytes their files carried.
    public private(set) var counts = ContainerError.Counts(entries: 0, bytes: 0)
    /// Whether `end` was admitted.
    public private(set) var isEnded = false
    /// The logical bytes the entries so far land, which the byte ceiling bounds.
    private var landedBytes: UInt64 = 0

    /// A sequence held to what `acceptance` admits.
    ///
    /// - Parameter acceptance: What the pull accepts.
    public init(accepting acceptance: ContainerAcceptance) {
        self.acceptance = acceptance
    }

    /// Admits `event`, the next of the stream.
    ///
    /// - Parameter event: The event.
    /// - Returns: What it asks of its consumer.
    /// - Throws: `ContainerError` naming the rule it breaks.
    @discardableResult
    public mutating func admit(_ event: TreeEvent) throws(ContainerError) -> Admitted {
        guard !isEnded else { throw .bytesAfterEnd }
        switch event {
        case .enterDirectory(let header), .beginFile(let header), .symlink(let header):
            return .entry(try admitEntry(header, as: event))
        case .bytes(let bytes):
            return try admitContent(UInt64(bytes.count))
        case .zeros(let count):
            return try admitContent(count)
        case .resourceFork:
            guard var file = openFile, file.part == .data else { throw .eventOutOfOrder }
            guard file.remaining == 0 else { throw .entryIncomplete(remaining: file.remaining) }
            guard file.entry.resourceForkByteCount > 0 else { throw .resourceForkUndeclared }
            file.part = .resourceFork
            file.remaining = file.entry.resourceForkByteCount
            openFile = file
        case .finishFile:
            guard let file = openFile else { throw .eventOutOfOrder }
            guard file.isWhole else { throw .entryIncomplete(remaining: file.owed) }
            openFile = nil
        case .leaveDirectory:
            if let openFile { throw .entryIncomplete(remaining: openFile.owed) }
            guard enteredDirectories > 0 else { throw .eventOutOfOrder }
            enteredDirectories -= 1
        case .end:
            if let openFile { throw .entryIncomplete(remaining: openFile.owed) }
            guard counts.entries > 0 else { throw .noEntry }
            guard enteredDirectories == 0 else { throw .eventOutOfOrder }
            isEnded = true
        }
        return .step
    }

    /// Admits `count` bytes of the open file's current part.
    ///
    /// - Parameter count: The bytes, as a chunk or event carries them.
    /// - Returns: The part and the offset into it they start at.
    /// - Throws: `ContainerError` naming the rule they break.
    public mutating func admitContent(_ count: UInt64) throws(ContainerError) -> Admitted {
        guard !isEnded else { throw .bytesAfterEnd }
        guard var file = openFile else { throw .chunkOutsideEntry }
        guard count > 0 else { throw .emptyChunk }
        guard count <= file.remaining else { throw .chunkPastEntrySize(count: count, remaining: file.remaining) }
        let size = file.part == .data ? file.entry.dataByteCount : file.entry.resourceForkByteCount
        let offset = size - file.remaining
        file.remaining -= count
        openFile = file
        counts.bytes += count
        return .content(file.part, offset: offset)
    }

    private mutating func admitEntry(_ header: EntryHeader, as event: TreeEvent) throws(ContainerError)
        -> ValidatedEntry
    {
        if let openFile { throw .entryIncomplete(remaining: openFile.owed) }
        try place(header, as: event)
        let entry = try ValidatedEntry(header)
        if entry.isLZ4 && !acceptance.acceptsLZ4 { throw .lz4NotAccepted }
        landedBytes = try acceptance.admitLanding(entry, after: landedBytes)
        counts.entries += 1
        switch header.type {
        case .directory: enteredDirectories += 1
        case .symlink: break
        default: openFile = OpenFile(entry: entry, remaining: entry.dataByteCount)
        }
        return entry
    }

    /// Checks that `header` is the entry `event` creates and lies where the stream is: the root first, of the
    /// pull's type, and every other entry inside the directories entered, at their depth.
    private func place(_ header: EntryHeader, as event: TreeEvent) throws(ContainerError) {
        let matches: Bool
        switch (header.type, event) {
        case (.unspecified, _), (.UNRECOGNIZED, _): throw .unknownEntryType
        case (.directory, .enterDirectory), (.symlink, .symlink), (.file, .beginFile), (.data, .beginFile):
            matches = true
        default: matches = false
        }
        guard matches else { throw .eventTypeMismatch(header.type) }
        if counts.entries == 0 {
            guard header.depth == 0 else { throw .firstEntryNotAtRoot(depth: header.depth) }
            guard header.type == Self.rootType(of: acceptance.storage) else {
                throw .rootTypeMismatch(header.type, expected: acceptance.storage)
            }
            return
        }
        guard header.type != .data else { throw .dataEntryNotRoot }
        guard header.depth > 0 else { throw .secondRootEntry }
        guard Int(header.depth) <= enteredDirectories else {
            throw .depthBeyondParent(depth: header.depth, enteredDirectories: enteredDirectories)
        }
        guard Int(header.depth) == enteredDirectories else {
            throw .directoryNotLeft(depth: header.depth, enteredDirectories: enteredDirectories)
        }
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
