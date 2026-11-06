#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaContainerPipeline
import KernovaFileTree
import KernovaLogging
import KernovaSynchronization

/// Lands a pulled representation from its container's bytes: a `ContainerDecodePipeline` feeding a
/// ``TreeWriter``. The item takes the name its caller supplies — the container's root carries none — only in
/// ``publish()``, after ``finish()`` has confirmed the container whole; any failure, or the receiver ending first,
/// removes everything it created.
///
/// Once a call has failed, the receiver takes no more bytes and holds none: whether the container or the writer
/// failed, the pipeline is released — which returns once none of its work is running — and every later call
/// throws that failure.
public final class TreeReceiver<FileSystem: MutableTreeFileSystem> {
    private enum State {
        case receiving(ContainerDecodePipeline)
        /// The container ended whole, and the pipeline is released.
        case finished
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

    /// A receiver landing what `acceptance` admits in `destination`, as the item `name`.
    ///
    /// - Parameters:
    ///   - name: The item's name, which it is published under, exactly or keeping both; the writer holds it to
    ///     what this OS lands.
    ///   - acceptance: What the pull accepts; its byte ceiling and decmpfs types bound the writer too.
    ///   - decodingWorkers: The lanes LZ4 chunks decompress on; 0 decompresses each in the caller.
    ///   - fileSystem: The calls the writer makes.
    ///   - destination: An open directory, which the receiver takes ownership of and closes when it ends.
    ///   - destinationPathByteCount: The length in bytes of the destination's absolute path.
    ///   - budget: What each landed entry's bytes are charged to, as ``TreeWriter`` charges them.
    ///   - logger: Where a staging root the writer could not remove is reported.
    public init(
        name: PublishName, accepting acceptance: ContainerAcceptance, decodingWorkers: Int, fileSystem: FileSystem,
        destination: Int32,
        destinationPathByteCount: Int, budget: ByteBudget? = nil, logger: KernovaLogger = TreeWriterLog.logger
    ) {
        state = .receiving(ContainerDecodePipeline(accepting: acceptance, workers: decodingWorkers))
        writer = TreeWriter(
            name: name, fileSystem: fileSystem, destination: destination,
            destinationPathByteCount: destinationPathByteCount,
            accepting: acceptance, budget: budget, logger: logger)
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

    /// Lands every entry still decompressing and confirms the container ended whole: the item is staged, under
    /// ``stagingName``, until ``publish()``.
    ///
    /// - Throws: ``TreeWriteFailure``, for a container that did not end whole or an entry that could not land;
    ///   nothing created then remains.
    public func finish() throws(TreeWriteFailure) {
        try latching { decoder throws(TreeWriteFailure) in
            decoder.finish()
            try land(from: decoder)
            state = .finished
        }
    }

    /// Publishes the finished item in the destination under the name it was created with, never replacing
    /// anything the receiver did not create.
    ///
    /// - Returns: The name the item landed under.
    /// - Throws: ``TreeWriteFailure``: before ``finish()``, `eventOutOfOrder`; for a name that is taken,
    ///   `EEXIST` unless the name keeps both; nothing created then remains.
    public func publish() throws(TreeWriteFailure) -> [UInt8] {
        switch state {
        case .failed(let failure): throw failure
        case .receiving: throw writer.failHere(.container(.eventOutOfOrder))
        case .finished: break
        }
        do {
            return try writer.publish()
        } catch {
            state = .failed(error)
            throw error
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
        case .finished: throw writer.failHere(.container(.bytesAfterEnd))
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
