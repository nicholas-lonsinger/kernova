#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer

/// Which way a transfer's bytes travel.
public enum TransferDirection: Sendable, Equatable, CaseIterable {
    /// A guest agent sends, the host receives.
    case guestToHost
    /// The host sends, a guest agent receives.
    case hostToGuest
}

/// How the sending side compresses one transfer, chosen once before its first entry by
/// `forSending(_:pullAcceptsLZ4:sendingCores:)` and fixed for the transfer.
///
/// Only a file whose storage is LZ4 has chunks the writer tries, so decmpfs storage — bytes the source volume
/// already compressed, passed through as they are — is never tried, whatever this says.
public struct TransferCompression: Equatable, Sendable {
    /// Whether files go as LZ4 storage, so their chunks may be LZ4 blocks.
    public var storesLZ4: Bool
    /// When the writer tries LZ4 on a chunk.
    public var chunkPolicy: ChunkCompressionPolicy
    /// The lanes `ContainerEncodePipeline` tries chunks on.
    public var encodingWorkers: Int

    /// A choice of the given parts.
    ///
    /// - Parameters:
    ///   - storesLZ4: Whether files go as LZ4 storage.
    ///   - chunkPolicy: When the writer tries LZ4 on a chunk.
    ///   - encodingWorkers: The lanes chunks are tried on.
    public init(storesLZ4: Bool, chunkPolicy: ChunkCompressionPolicy, encodingWorkers: Int) {
        self.storesLZ4 = storesLZ4
        self.chunkPolicy = chunkPolicy
        self.encodingWorkers = encodingWorkers
    }

    /// Every file plain, every chunk raw, nothing handed to a lane.
    public static let uncompressed = TransferCompression(storesLZ4: false, chunkPolicy: .never, encodingWorkers: 0)

    // PROVISIONAL: no constant below has been measured in a guest; #1707 tracks the measurement.

    /// The fewest cores a sender compresses with. From the Swift codec's single-thread rates, text and binaries
    /// pass break-even between two and three encoding cores and code-like payloads at two
    /// (docs/research/2026-11-02-swift-lz4-against-lz4-raw.md, finding 5).
    public static let minimumEncodingCores = 3

    /// The most lanes a sender tries chunks on; each adds two chunks to the pipeline's window.
    public static let maximumEncodingWorkers = 8

    /// Tried chunks of one entry in a row that did not shrink, after which its remaining chunks go raw: 1 MiB of
    /// 256 KiB chunks.
    public static let abandonAfterUnshrunkChunks = 4

    /// The most lanes a receiver decompresses on.
    public static let maximumDecodingWorkers = 4

    /// The compression a sender uses for one transfer.
    ///
    /// Compresses only guest to host, only when the pull lists LZ4, and only on at least `minimumEncodingCores`;
    /// then on one lane per core up to `maximumEncodingWorkers`, abandoning an entry after
    /// `abandonAfterUnshrunkChunks` chunks in a row that did not shrink.
    ///
    /// - Parameters:
    ///   - direction: Which way the transfer goes.
    ///   - pullAcceptsLZ4: Whether the pull lists LZ4 among its codecs.
    ///   - sendingCores: The cores active on the sending side.
    /// - Returns: The compression, `uncompressed` unless every condition holds.
    public static func forSending(_ direction: TransferDirection, pullAcceptsLZ4: Bool, sendingCores: Int)
        -> TransferCompression
    {
        guard direction == .guestToHost, pullAcceptsLZ4, sendingCores >= minimumEncodingCores else {
            return .uncompressed
        }
        return TransferCompression(
            storesLZ4: true,
            chunkPolicy: ChunkCompressionPolicy(
                attemptsLZ4: true, abandonAfterUnshrunkChunks: abandonAfterUnshrunkChunks),
            encodingWorkers: min(sendingCores, maximumEncodingWorkers))
    }

    /// The lanes a receiver decompresses on: none on one core, where a lane would only take turns with the
    /// caller, otherwise one per core up to `maximumDecodingWorkers`.
    ///
    /// - Parameter receivingCores: The cores active on the receiving side.
    /// - Returns: The lane count for `ContainerDecodePipeline`.
    public static func decodingWorkers(receivingCores: Int) -> Int {
        receivingCores < 2 ? 0 : min(receivingCores, maximumDecodingWorkers)
    }

    /// `acceptance` as the sender's reader and encoder take it: LZ4 only where the pull accepts it and this
    /// compresses, since a reader stores files as LZ4 exactly when its acceptance takes LZ4.
    ///
    /// - Parameter acceptance: What the pull accepts.
    /// - Returns: `acceptance`, taking LZ4 only when both do.
    public func sending(_ acceptance: ContainerAcceptance) -> ContainerAcceptance {
        var sending = acceptance
        sending.acceptsLZ4 = acceptance.acceptsLZ4 && storesLZ4
        return sending
    }
}
