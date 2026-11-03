#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaContainerPipeline
import KernovaWire
import Testing

@Suite("Transfer compression policy")
struct TransferCompressionTests {
    static let compressing = ChunkCompressionPolicy(
        attemptsLZ4: true, abandonAfterUnshrunkChunks: TransferCompression.abandonAfterUnshrunkChunks)

    /// Direction, whether the pull lists LZ4, the sending cores, and the choice.
    static let table: [(TransferDirection, Bool, Int, TransferCompression)] = {
        let minimum = TransferCompression.minimumEncodingCores
        let maximum = TransferCompression.maximumEncodingWorkers
        func lz4(_ workers: Int) -> TransferCompression {
            TransferCompression(storesLZ4: true, chunkPolicy: compressing, encodingWorkers: workers)
        }
        return [
            (.guestToHost, true, 1, .uncompressed),
            (.guestToHost, true, minimum - 1, .uncompressed),
            (.guestToHost, true, minimum, lz4(minimum)),
            (.guestToHost, true, maximum, lz4(maximum)),
            (.guestToHost, true, maximum * 4, lz4(maximum)),
            (.guestToHost, false, maximum, .uncompressed),
            (.hostToGuest, true, maximum * 4, .uncompressed),
            (.hostToGuest, true, minimum, .uncompressed),
            (.hostToGuest, false, 1, .uncompressed),
        ]
    }()

    @Test("a sender compresses only guest to host, when the pull lists LZ4, on enough cores")
    func choosesFromItsInputs() {
        for (direction, acceptsLZ4, cores, expected) in Self.table {
            #expect(
                TransferCompression.forSending(direction, pullAcceptsLZ4: acceptsLZ4, sendingCores: cores) == expected,
                "\(direction), LZ4 \(acceptsLZ4), \(cores) cores")
        }
        #expect(TransferCompression.uncompressed.encodingWorkers == 0)
        #expect(TransferCompression.uncompressed.chunkPolicy == .never)
    }

    @Test("a receiver decompresses in the caller on one core and on a lane per core up to the cap")
    func decodingWorkers() {
        let maximum = TransferCompression.maximumDecodingWorkers
        #expect(TransferCompression.decodingWorkers(receivingCores: 1) == 0)
        #expect(TransferCompression.decodingWorkers(receivingCores: 2) == 2)
        #expect(TransferCompression.decodingWorkers(receivingCores: maximum) == maximum)
        #expect(TransferCompression.decodingWorkers(receivingCores: maximum * 8) == maximum)
    }

    @Test("the sender's acceptance takes LZ4 only where the pull does and the choice compresses")
    func narrowsAcceptance() {
        let compressing = TransferCompression.forSending(.guestToHost, pullAcceptsLZ4: true, sendingCores: 16)
        var noLZ4 = generous(.folder)
        noLZ4.acceptsLZ4 = false
        #expect(compressing.sending(generous(.folder)).acceptsLZ4)
        #expect(!compressing.sending(noLZ4).acceptsLZ4)
        #expect(!TransferCompression.uncompressed.sending(generous(.folder)).acceptsLZ4)
        #expect(compressing.sending(generous(.folder)).byteCeiling == generous(.folder).byteCeiling)
    }

    @Test("decmpfs storage is never tried, however compressible its bytes")
    func decmpfsGoesRaw() throws {
        let choice = TransferCompression.forSending(.guestToHost, pullAcceptsLZ4: true, sendingCores: 16)
        let fork = Data(repeating: 0x61, count: ContainerEncoder.chunkByteCount * 3)
        let tree: [TreeEvent] = [
            .beginFile(
                decmpfsFile(
                    "f", depth: 0, attribute: decmpfsAttribute(type: 4, size: 1 << 20),
                    resourceForkSize: UInt64(fork.count))),
            .resourceFork, .bytes(fork), .finishFile, .end,
        ]
        let pipeline = ContainerEncodePipeline(
            accepting: choice.sending(generous(.file)), policy: choice.chunkPolicy, workers: choice.encodingWorkers)
        var container = Data()
        for event in tree { container.append(try pipeline.encode(event)) }
        let kinds = recordOffsets(container).map(\.kind)
        #expect(kinds.filter { $0 == .chunk }.count == 3)
        #expect(!kinds.contains(.lz4Chunk))
    }
}
