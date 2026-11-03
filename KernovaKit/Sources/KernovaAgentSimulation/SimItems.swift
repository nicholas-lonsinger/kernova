#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaContainer
import KernovaWire

/// The simulation's offered items. Each representation's tree is generated from the pull that names it, so
/// the serving side's source and the pulling side's checks derive the same bytes.
package enum SimItems {
    /// The 16-byte token `tag` names.
    package static func token(_ tag: UInt8) -> Data { Data(repeating: tag, count: 16) }

    /// A representation of `storage` whose tree carries `size` bytes.
    package static func representation(_ storage: Representation.Storage, size: Int) -> Representation {
        var representation = Representation()
        representation.type.mime = storage == .inline ? "text/plain" : "application/octet-stream"
        representation.storage = storage
        representation.sizeEstimate = UInt64(size)
        return representation
    }

    /// An offer of `items`, each its representations.
    package static func offer(_ tag: UInt8, _ items: [[Representation]]) -> ItemOffer {
        ItemOffer(
            token: token(tag),
            items: items.map { representations in
                var item = OfferedItem()
                item.representations = representations
                return item
            })
    }

    /// A pull of representation `representation` of item `item` of the offer `tag` names.
    package static func request(
        _ tag: UInt8, item: UInt32 = 0, representation: UInt32 = 0, ceiling: UInt64 = 1 << 40
    ) -> PullRequest {
        var request = PullRequest()
        request.token = token(tag)
        request.item = item
        request.representation = representation
        request.byteCeiling = ceiling
        return request
    }

    /// The entries `representation` sends for `request`, each with the bytes it carries: INLINE one DATA
    /// entry; FILE one file; FOLDER a folder holding a file and a subfolder holding the other half.
    package static func tree(_ request: PullRequest, _ representation: Representation) -> [(EntryHeader, Data)] {
        var hash = FNV64()
        hash.add(request.token)
        hash.add(UInt64(request.item) << 32 | UInt64(request.representation))
        let content = SimPayload.content(size: Int(representation.sizeEstimate), tag: hash.value)
        switch representation.storage {
        case .inline:
            var header = EntryHeader()
            header.type = .data
            header.plain.size = UInt64(content.count)
            return [(header, content)]
        case .folder:
            let half = content.count / 2
            return [
                (directory("folder", depth: 0), Data()),
                (file("a", depth: 1, size: half), content.prefix(half)),
                (directory("sub", depth: 1), Data()),
                (file("b", depth: 2, size: content.count - half), content.dropFirst(half)),
            ]
        default:
            return [(file("item", depth: 0, size: content.count), content)]
        }
    }

    /// The container of `request`'s tree, held to `acceptance`.
    package static func container(
        _ request: PullRequest, _ representation: Representation, accepting acceptance: ContainerAcceptance
    ) throws(ContainerError) -> Data {
        var encoder = ContainerEncoder(accepting: acceptance, policy: .never)
        var container = Data()
        for (header, bytes) in tree(request, representation) {
            container.append(try encoder.entry(header))
            container.append(try encoder.bytes(bytes))
        }
        container.append(try encoder.end())
        return container
    }

    /// The CRC32C of the bytes `request`'s tree carries, in order: what a sink that landed it reports.
    package static func digest(_ request: PullRequest, _ representation: Representation) -> UInt32 {
        var crc = CRC32C()
        for (_, bytes) in tree(request, representation) { crc.update(bytes) }
        return crc.value
    }

    /// The code a pull ends with when `error` refuses its container under `acceptance`.
    package static func wireError(_ error: ContainerError, _ acceptance: ContainerAcceptance) -> WireError {
        WireError(
            error.errorCode, limit: error.errorCode == .tooLarge ? acceptance.byteCeiling : 0,
            debugDetail: "\(error)")
    }

    static func file(_ name: String, depth: UInt32, size: Int) -> EntryHeader {
        var header = EntryHeader()
        header.depth = depth
        header.name = Data(name.utf8)
        header.type = .file
        header.mode = 0o644
        header.plain.size = UInt64(size)
        return header
    }

    static func directory(_ name: String, depth: UInt32) -> EntryHeader {
        var header = EntryHeader()
        header.depth = depth
        header.name = Data(name.utf8)
        header.type = .directory
        header.mode = 0o755
        return header
    }
}

/// An item source serving `SimItems` containers from memory, a read at a time.
package struct ContainerItemSource: Sendable {
    /// Encode as though the pull had no byte ceiling: a source that ignores the puller's limit.
    package var ignoresCeiling = false
    private var containers: [ItemPullID: (bytes: Data, offset: Int)] = [:]

    package init() {}

    /// The containers held: one per pull served and not yet released.
    package var heldCount: Int { containers.count }

    /// The answer to `effect`, if it takes one.
    package mutating func handle(_ effect: ItemSourceEffect) -> ItemSourceInput? {
        switch effect {
        case .serve(let id, let request, let representation):
            var acceptance = ContainerAcceptance(request, storage: representation.storage)
            if ignoresCeiling { acceptance.byteCeiling = .max }
            do {
                containers[id] = (try SimItems.container(request, representation, accepting: acceptance), 0)
                return nil
            } catch {
                return .failed(id, SimItems.wireError(error, acceptance))
            }
        case .read(let id, let maxBytes):
            guard let (bytes, offset) = containers[id] else { return nil }
            guard offset < bytes.count else { return .finished(id) }
            let end = min(offset + maxBytes, bytes.count)
            containers[id]?.offset = end
            return .bytes(id, bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + end)))
        case .release(let id):
            containers[id] = nil
            return nil
        }
    }
}

/// An item sink that only decodes: it feeds each pull's container to a `ContainerDecoder`, stages the digest
/// of the bytes it decodes, and lands that digest on `.commit`. It records any effect that breaks the sink
/// contract.
package struct DecodingItemSink {
    private struct Pull {
        var decoder: ContainerDecoder
        var acceptance: ContainerAcceptance
        var digest = CRC32C()
    }

    private var pulls: [ItemPullID: Pull] = [:]
    private var staged: [ItemPullID: UInt32] = [:]
    private var begun: Set<ItemPullID> = []
    private var terminated: Set<ItemPullID> = []
    /// Each committed pull's digest: the CRC32C of the bytes its entries carried.
    package private(set) var landed: [ItemPullID: UInt32] = [:]
    /// The most input any decoder held at once.
    package private(set) var maxBufferedBytes = 0
    package private(set) var violations: [String] = []

    package init() {}

    /// Whether the sink still holds anything of `id`.
    package func holds(_ id: ItemPullID) -> Bool { pulls[id] != nil || staged[id] != nil }

    /// The answer to `effect`, if it takes one.
    package mutating func handle(_ effect: ItemSinkEffect) -> ItemSinkInput? {
        switch effect {
        case .begin(let id, let request, let representation):
            guard begun.insert(id).inserted else {
                violations.append("pull \(id.stream.rawValue) begun twice")
                return nil
            }
            let acceptance = ContainerAcceptance(request, storage: representation.storage)
            pulls[id] = Pull(decoder: ContainerDecoder(accepting: acceptance), acceptance: acceptance)
            return nil
        case .bytes(let id, let bytes):
            if terminated.contains(id) { violations.append("bytes for pull \(id.stream.rawValue) after its end") }
            // Bytes for a pull it refused, delivered before the refusal reached the core.
            guard var pull = pulls[id] else { return nil }
            pull.decoder.feed(bytes)
            maxBufferedBytes = max(maxBufferedBytes, pull.decoder.bufferedByteCount)
            do {
                try Self.drain(&pull)
            } catch {
                pulls[id] = nil
                return .refused(id, SimItems.wireError(error, pull.acceptance))
            }
            pulls[id] = pull
            return .consumed(id, bytes.count)
        case .finish(let id):
            if terminated.contains(id) { violations.append("finish for pull \(id.stream.rawValue) after its end") }
            guard var pull = pulls.removeValue(forKey: id) else { return nil }
            do {
                try Self.drain(&pull)
                try pull.decoder.finish()
            } catch {
                return .refused(id, SimItems.wireError(error, pull.acceptance))
            }
            staged[id] = pull.digest.value
            return .verified(id)
        case .commit(let id):
            terminate(id)
            guard let digest = staged.removeValue(forKey: id) else {
                violations.append("commit of pull \(id.stream.rawValue), which is not verified")
                return nil
            }
            landed[id] = digest
            return nil
        case .abort(let id):
            terminate(id)
            pulls[id] = nil
            staged[id] = nil
            return nil
        }
    }

    private mutating func terminate(_ id: ItemPullID) {
        if !begun.contains(id) { violations.append("pull \(id.stream.rawValue) ended, never begun") }
        if !terminated.insert(id).inserted { violations.append("pull \(id.stream.rawValue) ended twice") }
    }

    private static func drain(_ pull: inout Pull) throws(ContainerError) {
        while let event = try pull.decoder.next() {
            switch event {
            case .bytes(let bytes): pull.digest.update(bytes)
            case .zeros(let count): pull.digest.update(Data(count: Int(count)))
            default: break
            }
        }
    }
}
