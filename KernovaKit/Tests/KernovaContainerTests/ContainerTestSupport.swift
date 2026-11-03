#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf

/// A pull of a `storage` representation accepting LZ4, decmpfs type 4, and up to 1 GiB.
func generous(_ storage: Representation.Storage = .file) -> ContainerAcceptance {
    ContainerAcceptance(storage: storage, byteCeiling: 1 << 30, decmpfsTypes: [4], acceptsLZ4: true)
}

/// The storage whose representation sends `type` as its root entry.
func storage(sending type: EntryHeader.TypeEnum) -> Representation.Storage {
    switch type {
    case .data: .inline
    case .directory: .folder
    default: .file
    }
}

/// `generous` for the representation a container's first record, a header, says it is; a file pull when the
/// container does not start with a decodable header.
func generous(for container: Data) -> ContainerAcceptance {
    let prefix = ContainerRecord.prefixByteCount
    guard container.count >= prefix, container[container.startIndex] == ContainerRecordKind.header.rawValue else {
        return generous()
    }
    let length = (0..<4).reduce(0) { $0 | Int(container[container.startIndex + 1 + $1]) << ($1 * 8) }
    let start = container.startIndex + prefix
    guard container.count >= prefix + length,
        let header = try? EntryHeader(serializedBytes: container[start..<(start + length)])
    else { return generous() }
    return generous(storage(sending: header.type))
}

func name(_ text: String) -> Data { Data(text.utf8) }

func plainFile(_ fileName: String, depth: UInt32, size: UInt64) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = name(fileName)
    header.type = .file
    header.mode = 0o644
    header.plain.size = size
    return header
}

func lz4File(_ fileName: String, depth: UInt32, size: UInt64) -> EntryHeader {
    var header = plainFile(fileName, depth: depth, size: size)
    header.lz4.size = size
    return header
}

func directory(_ directoryName: String, depth: UInt32) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = name(directoryName)
    header.type = .directory
    header.mode = 0o755
    return header
}

func symlink(_ linkName: String, depth: UInt32, target: String) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = name(linkName)
    header.type = .symlink
    header.symlinkTarget = Data(target.utf8)
    return header
}

func inlineData(size: UInt64) -> EntryHeader {
    var header = EntryHeader()
    header.type = .data
    header.plain.size = size
    return header
}

/// A `com.apple.decmpfs` attribute: a `decmpfs_disk_header` of `type` and `size`, then `tail`.
func decmpfsAttribute(type: UInt32, size: UInt64, magic: UInt32 = DecmpfsHeader.magic, tail: Data = Data()) -> Data {
    var attribute = Data()
    for value in [UInt64(magic), UInt64(type)] {
        attribute.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    attribute.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
    attribute.append(tail)
    return attribute
}

func decmpfsFile(_ fileName: String, depth: UInt32, attribute: Data, resourceForkSize: UInt64) -> EntryHeader {
    var header = plainFile(fileName, depth: depth, size: 0)
    header.decmpfs.attribute = attribute
    header.decmpfs.resourceForkSize = resourceForkSize
    return header
}

func serialized(_ message: some SwiftProtobuf.Message) -> Data {
    do {
        return try message.serializedBytes()
    } catch {
        preconditionFailure("a proto3 message always serializes: \(error)")
    }
}

/// One record, framed by the codec's own framing, for containers the encoder refuses to write.
func record(_ kind: ContainerRecordKind, _ payload: Data) -> Data {
    var data = Data()
    ContainerRecord.append(kind, payload: payload, to: &data)
    return data
}

/// One record with any kind byte and payload, and a correct checksum over them.
func rawRecord(kind: UInt8, payload: Data) -> Data {
    let prefix = Data([kind]) + littleEndian(UInt32(payload.count))
    var crc = CRC32C()
    crc.update(prefix)
    crc.update(payload)
    return prefix + littleEndian(crc.value) + payload
}

func littleEndian<Integer: FixedWidthInteger>(_ value: Integer) -> Data {
    Data((0..<(Integer.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

func headerRecord(_ header: EntryHeader) -> Data { record(.header, serialized(header)) }

func endRecord(entries: UInt64, bytes: UInt64) -> Data {
    var end = EndRecord()
    end.entries = entries
    end.bytes = bytes
    return record(.end, serialized(end))
}

func zeroRunRecord(_ count: UInt64) -> Data { record(.zeroRun, littleEndian(count)) }

func lz4ChunkRecord(declaredSize: UInt32, block: Data) -> Data {
    record(.lz4Chunk, littleEndian(declaredSize) + block)
}

/// What decoding a container came to.
struct Decoded {
    var events: [TreeEvent] = []
    var error: ContainerError?
    /// The most input the decoder held after `next()` returned nil.
    var largestResidue = 0
    /// The most bytes one `bytes` event carried.
    var largestEvent = 0

    var succeeded: Bool { error == nil }
}

/// Decodes `container` fed in pieces of `pieceSize` bytes (all at once when nil), then finishes.
/// Without `acceptance`, a generous pull of the representation the container's root header says it is.
func decode(_ container: Data, accepting acceptance: ContainerAcceptance? = nil, pieceSize: Int? = nil) -> Decoded {
    var decoder = ContainerDecoder(accepting: acceptance ?? generous(for: container))
    var result = Decoded()
    let step = max(1, pieceSize ?? container.count)
    var start = container.startIndex
    repeat {
        let end = min(start + step, container.endIndex)
        decoder.feed(container[start..<end])
        start = end
        do {
            while let event = try decoder.next() {
                if case .bytes(let bytes) = event { result.largestEvent = max(result.largestEvent, bytes.count) }
                result.events.append(event)
            }
            result.largestResidue = max(result.largestResidue, decoder.bufferedByteCount)
        } catch {
            result.error = error
            return result
        }
    } while start < container.endIndex
    do {
        try decoder.finish()
    } catch {
        result.error = error
    }
    return result
}

/// The error decoding `container` ends with, or nil when it decodes.
func decodingError(_ container: Data, accepting acceptance: ContainerAcceptance? = nil) -> ContainerError? {
    decode(container, accepting: acceptance).error
}

/// A file's content as the events carry it, zero runs expanded.
func content(of events: [TreeEvent]) -> Data {
    var data = Data()
    for event in events {
        switch event {
        case .bytes(let bytes): data.append(bytes)
        case .zeros(let count): data.append(Data(count: Int(count)))
        default: break
        }
    }
    return data
}

/// A tree to encode: each entry with the bytes its file carries.
struct TreeFixture {
    var entries: [(header: EntryHeader, bytes: Data)]

    /// The records of the whole tree, `bytes` fed to the encoder in pieces of `pieceSize`.
    func encoded(
        accepting acceptance: ContainerAcceptance? = nil, policy: ChunkCompressionPolicy = .never,
        pieceSize: Int = 100_000
    ) throws(ContainerError) -> Data {
        let rootStorage = entries.first.map { storage(sending: $0.header.type) } ?? .file
        var encoder = ContainerEncoder(accepting: acceptance ?? generous(rootStorage), policy: policy)
        var container = Data()
        for (header, bytes) in entries {
            container.append(try encoder.entry(header))
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = min(start + pieceSize, bytes.endIndex)
                container.append(try encoder.bytes(bytes[start..<end]))
                start = end
            }
        }
        container.append(try encoder.end())
        return container
    }

    /// A tree of every entry type and storage: directories two deep, a multi-chunk random file, a sparse file
    /// with data between zero spans, compressible text, an empty file, a symlink and a decmpfs file.
    static func mixed(seed: UInt64 = 7) -> TreeFixture {
        var generator = SplitMix64(seed: seed)
        let random = generator.bytes(600_000)
        var sparse = Data(count: 700_000)
        sparse.replaceSubrange(300_000..<300_010, with: generator.bytes(10))
        let text = Data(String(repeating: "the guest agent streams a container. ", count: 20_000).utf8)
        let fork = generator.bytes(5_000)
        return TreeFixture(entries: [
            (directory("root", depth: 0), Data()),
            (plainFile("random", depth: 1, size: UInt64(random.count)), random),
            (directory("nested", depth: 1), Data()),
            (plainFile("sparse", depth: 2, size: UInt64(sparse.count)), sparse),
            (lz4File("text", depth: 2, size: UInt64(text.count)), text),
            (plainFile("empty", depth: 2, size: 0), Data()),
            (symlink("link", depth: 1, target: "nested/text"), Data()),
            (
                decmpfsFile(
                    "compressed", depth: 1, attribute: decmpfsAttribute(type: 4, size: 9_000),
                    resourceForkSize: UInt64(fork.count)), fork
            ),
        ])
    }

    /// The events this tree decodes to, with each file's bytes as one `bytes` event.
    var expectedEvents: [TreeEvent] {
        var events: [TreeEvent] = []
        var entered = 0
        for (header, bytes) in entries {
            while entered > Int(header.depth) {
                events.append(.leaveDirectory)
                entered -= 1
            }
            switch header.type {
            case .directory:
                events.append(.enterDirectory(header))
                entered += 1
            case .symlink:
                events.append(.symlink(header))
            default:
                events.append(.beginFile(header))
                if !bytes.isEmpty { events.append(.bytes(bytes)) }
                events.append(.finishFile)
            }
        }
        events += Array(repeating: .leaveDirectory, count: entered)
        events.append(.end)
        return events
    }
}

/// `events` with each file's consecutive `bytes` and `zeros` merged into one `bytes` event.
func coalesced(_ events: [TreeEvent]) -> [TreeEvent] {
    var result: [TreeEvent] = []
    var pending: Data?
    for event in events {
        switch event {
        case .bytes(let bytes):
            pending = (pending ?? Data()) + bytes
        case .zeros(let count):
            pending = (pending ?? Data()) + Data(count: Int(count))
        default:
            if let data = pending {
                result.append(.bytes(data))
                pending = nil
            }
            result.append(event)
        }
    }
    return result
}

/// The byte offset and kind of each record in a well-formed container.
func recordOffsets(_ container: Data) -> [(offset: Int, kind: ContainerRecordKind)] {
    var offsets: [(Int, ContainerRecordKind)] = []
    var offset = 0
    while offset < container.count {
        let base = container.startIndex + offset
        guard let kind = ContainerRecordKind(rawValue: container[base]) else { break }
        let length = (0..<4).reduce(0) { $0 | Int(container[base + 1 + $1]) << ($1 * 8) }
        offsets.append((offset, kind))
        offset += ContainerRecord.prefixByteCount + length
    }
    return offsets
}
