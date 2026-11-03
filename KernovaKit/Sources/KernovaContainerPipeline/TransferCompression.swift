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

    // Each constant below is derived in docs/research/2026-11-03-transfer-compression-policy.md: compression has
    // to beat plain bytes end to end over the ~750 MiB/s guest-to-host link, for every payload the guest sends.

    /// The fewest cores a sender compresses with. At 4, a Linux guest's text encode stays short of the link (716 and
    /// 737 MiB/s in two runs, on 4 lanes); at 5, on the 4 lanes `forSending` gives it, text reaches 936 MiB/s and
    /// every compressible payload measured gains 1.25× or more (the note's finding 2).
    public static let minimumEncodingCores = 5

    /// The most lanes a sender tries chunks on. At the host's per-core rates, eight lanes put code, text and binaries
    /// past the link's rate divided by their ratio, so a ninth lane cannot raise throughput (the note's finding 3).
    public static let maximumEncodingWorkers = 8

    /// Tried chunks of one entry in a row that did not shrink, after which its remaining chunks go raw. With 4, media
    /// still encodes at 1,400 MiB/s or more in every guest measured, so it never holds a transfer below the link (the
    /// note's finding 4).
    public static let abandonAfterUnshrunkChunks = 4

    /// The most lanes a receiver decompresses on. Four keep the host's decode at 1.98 times the link's rate divided
    /// by the ratio or more, for every compressible payload measured (the note's finding 5).
    public static let maximumDecodingWorkers = 4

    /// The compression a sender uses for one transfer.
    ///
    /// Compresses only guest to host, only when the pull lists LZ4, and only on at least `minimumEncodingCores`;
    /// then on a lane for every core but one, up to `maximumEncodingWorkers`, abandoning an entry after
    /// `abandonAfterUnshrunkChunks` chunks in a row that did not shrink. The core left over runs the caller, which
    /// reads, admits and writes every record; at 6 vCPUs a lane on it encoded 6–14% slower (the note's finding 1).
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
            encodingWorkers: min(sendingCores - 1, maximumEncodingWorkers))
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
