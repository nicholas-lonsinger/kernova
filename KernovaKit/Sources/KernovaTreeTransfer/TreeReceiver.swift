#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaContainerPipeline
import KernovaFileTree
import KernovaLogging

/// Lands a pulled FILE or FOLDER representation from its container's bytes: a `ContainerDecodePipeline` feeding a
/// ``TreeWriter``. The item takes its own name in the destination only in ``finish()``, once the pipeline has
/// confirmed the container whole; any failure, or the receiver ending first, removes everything it created.
///
/// Once a call has failed, the receiver takes no more bytes and holds none: whether the container or the writer
/// failed, the pipeline is released — which returns once none of its work is running — and every later call
/// throws that failure.
public final class TreeReceiver<FileSystem: MutableTreeFileSystem> {
    private enum State {
        case receiving(ContainerDecodePipeline)
        case failed(TreeWriteFailure)
    }

    private var state: State
    private let writer: TreeWriter<FileSystem>

    /// The container bytes held: those not yet decoded, and the window's.
    var heldByteCount: Int {
        guard case .receiving(let decoder) = state else { return 0 }
        return decoder.bufferedByteCount + decoder.heldBytes
    }

    /// The name the item has in the destination until it is published.
    public var stagingName: [UInt8] { writer.stagingName }

    /// A receiver landing what `acceptance` admits in `destination`.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull accepts; its byte ceiling and decmpfs types bound the writer too.
    ///   - decodingWorkers: The lanes LZ4 chunks decompress on; 0 decompresses each in the caller.
    ///   - fileSystem: The calls the writer makes.
    ///   - destination: An open directory, which the receiver takes ownership of and closes when it ends.
    ///   - destinationPathByteCount: The length in bytes of the destination's absolute path.
    ///   - logger: Where a staging root the writer could not remove is reported.
    public init(
        accepting acceptance: ContainerAcceptance, decodingWorkers: Int, fileSystem: FileSystem, destination: Int32,
        destinationPathByteCount: Int, logger: KernovaLogger = TreeWriterLog.logger
    ) {
        state = .receiving(ContainerDecodePipeline(accepting: acceptance, workers: decodingWorkers))
        writer = TreeWriter(
            fileSystem: fileSystem, destination: destination, destinationPathByteCount: destinationPathByteCount,
            accepting: acceptance, logger: logger)
    }

    /// Takes the container's next bytes, landing the entries they complete as their decompression completes: an entry
    /// can land in a later call, and lands by ``finish()`` at the latest. A chunk that fails to decompress can likewise
    /// fail a later call rather than this one.
    ///
    /// - Parameter bytes: The bytes following those received before.
    /// - Throws: ``TreeWriteFailure``; everything created is then removed, and every later call throws it.
    public func receive(_ bytes: Data) throws(TreeWriteFailure) {
        try latching { decoder throws(TreeWriteFailure) in
            decoder.feed(bytes)
            try land(from: decoder)
        }
    }

    /// Lands every entry still decompressing, confirms the container ended whole, and publishes the item under its own
    /// name.
    ///
    /// - Returns: The name the item landed under in the destination.
    /// - Throws: ``TreeWriteFailure``, for a container that did not end whole or an item that could not take
    ///   its name — `EEXIST` when the destination already holds it, `invalidName` when it carries none; nothing
    ///   created then remains.
    public func finish() throws(TreeWriteFailure) -> [UInt8] {
        try finish(as: nil)
    }

    /// ``finish()``, publishing the item as `name` exactly rather than under the name it carries.
    public func finish(publishingAs name: [UInt8]) throws(TreeWriteFailure) {
        _ = try finish(as: name)
    }

    private func finish(as name: [UInt8]?) throws(TreeWriteFailure) -> [UInt8] {
        try latching { decoder throws(TreeWriteFailure) in
            decoder.finish()
            try land(from: decoder)
            return try writer.publish(as: name)
        }
    }

    /// Writes every event `decoder` has ready.
    private func land(from decoder: ContainerDecodePipeline) throws(TreeWriteFailure) {
        while true {
            let event: TreeEvent?
            do throws(ContainerError) {
                event = try decoder.next()
            } catch {
                throw writer.failHere(.container(error))
            }
            guard let event else { return }
            try writer.write(event)
        }
    }

    /// Runs `body` with the pipeline unless a call already failed, keeping the failure it throws and releasing the
    /// pipeline.
    private func latching<Result>(_ body: (ContainerDecodePipeline) throws(TreeWriteFailure) -> Result)
        throws(TreeWriteFailure) -> Result
    {
        let decoder: ContainerDecodePipeline
        switch state {
        case .failed(let failure): throw failure
        case .receiving(let receiving): decoder = receiving
        }
        do {
            return try body(decoder)
        } catch {
            state = .failed(error)
            throw error
        }
    }
}
