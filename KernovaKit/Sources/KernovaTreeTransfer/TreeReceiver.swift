#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaFileTree
import KernovaLogging

/// Lands a pulled FILE or FOLDER representation from its container's bytes: a `ContainerDecoder` feeding a
/// ``TreeWriter``. The item takes its own name in the destination only in ``finish()``, once the decoder
/// has confirmed the container whole; any failure, or the receiver ending first, removes everything it
/// created.
///
/// Once a call has failed, the receiver takes no more bytes: whether the decoder or the writer failed, every
/// later call throws that failure before anything is fed or held.
public final class TreeReceiver<FileSystem: MutableTreeFileSystem> {
    private var decoder: ContainerDecoder
    private let writer: TreeWriter<FileSystem>
    private var failure: TreeWriteFailure?

    /// The container bytes held and not yet decoded.
    var heldByteCount: Int { decoder.bufferedByteCount }

    /// The name the item has in the destination until it is published.
    public var stagingName: [UInt8] { writer.stagingName }

    /// A receiver landing what `acceptance` admits in `destination`.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull accepts; its byte ceiling bounds the writer too.
    ///   - fileSystem: The calls the writer makes.
    ///   - destination: An open directory, which the receiver takes ownership of and closes when it ends.
    ///   - destinationPathByteCount: The length in bytes of the destination's absolute path.
    ///   - logger: Where a staging root the writer could not remove is reported.
    public init(
        accepting acceptance: ContainerAcceptance, fileSystem: FileSystem, destination: Int32,
        destinationPathByteCount: Int, logger: KernovaLogger = TreeWriterLog.logger
    ) {
        decoder = ContainerDecoder(accepting: acceptance)
        writer = TreeWriter(
            fileSystem: fileSystem, destination: destination, destinationPathByteCount: destinationPathByteCount,
            byteCeiling: acceptance.byteCeiling, logger: logger)
    }

    /// Takes the container's next bytes, landing every entry they complete.
    ///
    /// - Parameter bytes: The bytes following those received before.
    /// - Throws: ``TreeWriteFailure``; everything created is then removed, and every later call throws it.
    public func receive(_ bytes: Data) throws(TreeWriteFailure) {
        try latching { () throws(TreeWriteFailure) in
            decoder.feed(bytes)
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
    }

    /// Confirms the container ended whole and publishes the item under its own name.
    ///
    /// - Returns: The name the item landed under in the destination.
    /// - Throws: ``TreeWriteFailure``, for a container that did not end whole or an item that could not take
    ///   its name — `EEXIST` when the destination already holds it; nothing created then remains.
    public func finish() throws(TreeWriteFailure) -> [UInt8] {
        try latching { () throws(TreeWriteFailure) in
            do throws(ContainerError) {
                try decoder.finish()
            } catch {
                throw writer.failHere(.container(error))
            }
            return try writer.publish()
        }
    }

    /// Runs `body` unless a call already failed, keeping the failure it throws.
    private func latching<Result>(_ body: () throws(TreeWriteFailure) -> Result) throws(TreeWriteFailure) -> Result {
        if let failure { throw failure }
        do {
            return try body()
        } catch {
            failure = error
            throw error
        }
    }
}
