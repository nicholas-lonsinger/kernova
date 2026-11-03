#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer

/// Decodes a container as `ContainerDecoder` does — the same events, in the same order, and the same error at the
/// same point — while LZ4 chunks decompress on worker lanes.
///
/// Framing, checksums and every rule run in the caller, in stream order, through a `ContainerDecoder`: an LZ4 chunk's
/// declared size is admitted against its entry and the pull before its block is handed to a lane, so no lane allocates
/// past a limit. Each decoded item enters a window of twice the lane count (two with no lanes), and events leave it
/// oldest first, a refusal taking its place in that order. While the window is full, the caller waits for its oldest
/// item.
///
/// `feed(_:)` the container's bytes as they arrive and take events from `next()` until it returns nil, which it
/// does once nothing more can be decoded until more is fed; call `finish()` once the input ends, and keep taking
/// events: `next()` then waits for the work still out, and the container is whole only once it returns nil after
/// `finish()`. Fed after each nil, the pipeline holds at most one incomplete record, the latest feed, and the
/// window.
///
/// Releasing the pipeline drops what it holds and returns once no work it handed out is still running. After it
/// throws, it throws the same error from every call; it has then dropped everything.
public final class ContainerDecodePipeline {
    private let acceptance: ContainerAcceptance
    private var decoder: ContainerDecoder
    private let window: OrderedWindow<Result<TreeEvent, ContainerError>>
    /// Whether the decoder threw; its error is in the window, behind the events before it.
    private var decoderStopped = false
    private var inputEnded = false
    private var failure: ContainerError?

    /// A pipeline decoding a container `acceptance` admits, decompressing LZ4 chunks on `workers` lanes; 0
    /// decompresses each in the caller.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull accepts.
    ///   - workers: The lanes LZ4 chunks decompress on.
    public convenience init(accepting acceptance: ContainerAcceptance, workers: Int) {
        self.init(accepting: acceptance, workers: ChunkWorkers(count: workers))
    }

    package init(accepting acceptance: ContainerAcceptance, workers: ChunkWorkers) {
        self.acceptance = acceptance
        decoder = ContainerDecoder(accepting: acceptance)
        window = OrderedWindow(capacity: 2 * max(1, workers.count), workers: workers)
    }

    /// The input bytes held and not yet decoded.
    public var bufferedByteCount: Int { decoder.bufferedByteCount }
    /// The items held in the window.
    package var heldItems: Int { window.count }
    /// The bytes the window holds: each event's, and for a chunk in flight its block and its decompressed size.
    package var heldBytes: Int { window.heldBytes }
    /// The most items the window held at once.
    package var mostHeldItems: Int { window.mostHeld }
    /// The most bytes the window held at once.
    package var mostHeldBytes: Int { window.mostHeldBytes }
    /// The items the window holds at most.
    package var windowCapacity: Int { window.capacity }

    /// Takes the container's next bytes.
    ///
    /// - Parameter bytes: The bytes following those fed before.
    public func feed(_ bytes: Data) {
        guard failure == nil else { return }
        decoder.feed(bytes)
    }

    /// The input ended: from now on `next()` waits for the work still out, and its nil confirms the container
    /// whole.
    public func finish() {
        inputEnded = true
    }

    /// The next event, or nil: before `finish()`, when nothing more can be decoded until more is fed; after it,
    /// once the container is confirmed whole.
    ///
    /// - Returns: The event, or nil.
    /// - Throws: `ContainerError` when the container breaks a rule — after `finish()`, `.truncated` when the end
    ///   record never came and `.bytesAfterEnd` when bytes followed it.
    public func next() throws(ContainerError) -> TreeEvent? {
        if let failure { throw failure }
        while true {
            if let ready = window.takeReady() { return try delivered(ready) }
            if !decoderStopped {
                let evicted: Result<TreeEvent, ContainerError>?
                do {
                    guard let item = try decoder.nextItem() else { return try drained() }
                    evicted = hold(item)
                } catch {
                    decoderStopped = true
                    evicted = window.append(.failure(error), bytes: 0)
                }
                if let evicted { return try delivered(evicted) }
                continue
            }
            return try drained()
        }
    }

    /// What `next()` returns once the decoder has nothing more to admit: the oldest item, waited for, when no more
    /// input can come; nil when more input could, or once a finished container is confirmed whole.
    private func drained() throws(ContainerError) -> TreeEvent? {
        guard inputEnded || decoderStopped else { return nil }
        if let oldest = window.takeOldest() { return try delivered(oldest) }
        do {
            try decoder.finish()
        } catch {
            fail(error)
            throw error
        }
        return nil
    }

    private func hold(_ item: DecodedItem) -> Result<TreeEvent, ContainerError>? {
        switch item {
        case .event(let event):
            let bytes = if case .bytes(let data) = event { data.count } else { 0 }
            return window.append(.success(event), bytes: bytes)
        case .lz4Chunk(let chunk):
            return window.append(bytes: chunk.block.count + chunk.decompressedSize) {
                Result { () throws(ContainerError) in .bytes(try chunk.decompressed()) }
            }
        }
    }

    private func delivered(_ result: Result<TreeEvent, ContainerError>) throws(ContainerError) -> TreeEvent {
        switch result {
        case .success(let event):
            return event
        case .failure(let error):
            fail(error)
            throw error
        }
    }

    private func fail(_ error: ContainerError) {
        failure = error
        window.cancel()
        // Nothing is decoded after a failure, so an empty decoder drops the input held.
        decoder = ContainerDecoder(accepting: acceptance)
    }
}
