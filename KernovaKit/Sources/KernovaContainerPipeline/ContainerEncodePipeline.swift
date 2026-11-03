#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer

/// Encodes a container as `ContainerEncoder` does, byte for byte, while LZ4 is tried on chunks on worker lanes.
///
/// Each event is admitted in the caller, in stream order, through a `ContainerRecordAdmission`, so every rule refuses
/// an event before any chunk of it is handed out. Each record then enters a window of twice the lane count (two with no
/// lanes), an LZ4 candidate with an attempt started on the next lane; records leave the window oldest first into a
/// `ContainerRecordWriter`, which decides as it writes whether a candidate goes as its block, so an attempt made ahead
/// of the writer's decision changes no byte. While the window is full, the caller waits for its oldest record.
///
/// Releasing the pipeline drops what it holds and returns once no work it handed out is still running. After it
/// throws, it throws the same error from every call; it has then dropped everything.
public final class ContainerEncodePipeline {
    /// A record leaving the window, with the attempt made on it.
    struct Written: Sendable {
        var record: AdmittedRecord
        var attempt: LZ4Attempt
    }

    private var admission: ContainerRecordAdmission
    private var writer: ContainerRecordWriter
    private let window: OrderedWindow<Written>
    private var failure: ContainerError?

    /// A pipeline encoding a container `acceptance` admits, compressing chunks as `policy` allows on `workers`
    /// lanes; 0 tries every chunk in the caller.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull's destination accepts.
    ///   - policy: When to try LZ4 on a chunk.
    ///   - workers: The lanes LZ4 attempts run on.
    public convenience init(accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy, workers: Int) {
        self.init(accepting: acceptance, policy: policy, workers: ChunkWorkers(count: workers))
    }

    package init(accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy, workers: ChunkWorkers) {
        admission = ContainerRecordAdmission(accepting: acceptance)
        writer = ContainerRecordWriter(policy: policy)
        window = OrderedWindow(capacity: 2 * max(1, workers.count), workers: workers)
    }

    /// The records held in the window.
    package var heldRecords: Int { window.count }
    /// The most records the window held at once.
    package var mostHeldRecords: Int { window.mostHeld }
    /// The most chunk bytes the window held at once: each record's payload, and for an attempt in flight its
    /// chunk and as much again for its block.
    package var mostHeldBytes: Int { window.mostHeldBytes }
    /// The records the window holds at most.
    package var windowCapacity: Int { window.capacity }

    /// Takes the tree's next event and returns the records now written, in order: those whose turn has come and
    /// whose attempts are done. `.end` returns every record still held, so the container is whole once it
    /// returns.
    ///
    /// - Parameter event: The next event of a tree in depth-first pre-order.
    /// - Returns: The records' bytes, possibly none.
    /// - Throws: `ContainerError` when the event breaks a container rule.
    public func encode(_ event: TreeEvent) throws(ContainerError) -> Data {
        if let failure { throw failure }
        let records: [AdmittedRecord]
        do {
            records = try admission.admit(event)
        } catch {
            failure = error
            window.cancel()
            throw error
        }
        var output = Data()
        for record in records {
            let evicted: Written?
            switch record {
            case .lz4Candidate(let chunk, let entry) where writer.mayTry(candidateOf: entry):
                evicted = window.append(bytes: 2 * chunk.count) {
                    Written(record: record, attempt: .attempted(ContainerRecordWriter.lz4Payload(for: chunk)))
                }
            case .lz4Candidate(let chunk, _), .final(_, let chunk):
                evicted = window.append(Written(record: record, attempt: .notAttempted), bytes: chunk.count)
            }
            if let evicted { writer.write(evicted.record, attempt: evicted.attempt, to: &output) }
        }
        if case .end = event {
            while let written = window.takeOldest() {
                writer.write(written.record, attempt: written.attempt, to: &output)
            }
        } else {
            while let written = window.takeReady() {
                writer.write(written.record, attempt: written.attempt, to: &output)
            }
        }
        return output
    }
}
