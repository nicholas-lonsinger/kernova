// It lands through ItemSinkAdapter, which only Darwin and Linux have here.
#if canImport(Darwin) || os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaFileTree
import KernovaLogging
import KernovaSynchronization
import KernovaTransferProgress
import KernovaWire

/// A peer's DROP owner: it lands each offer the host drops into one directory, one item at a time in offer
/// order, each item's FILE or FOLDER representation under the offer's name for it, Keep Both-named against
/// what is already there. Once every item has ended it releases the offer, its END saying which items landed
/// (``DropLanded``), and hands `landed` the names it published.
///
/// An item the host cannot serve is skipped. A landing that fails, or a landing directory this side cannot
/// open, stops the drop: it refuses the offer with that error, so the host hears why. An offer the host
/// withdraws lands nothing more, and hands `landed` nothing.
///
/// Each drop reports on one readout, each item's pull a unit its landing feeds. The receiver reads every item
/// of the offer before its first pull, so the readout counts the whole drop from its first report: every item it
/// will pull, and their bytes when each has an estimate. The readout begins once the first item's landing is
/// ordered, which opens the landing directory, so its clock leaves out the time the OS took asking the user. Its
/// Cancel refuses the offer `CANCELLED`, which ends the pull in flight with it.
///
/// Its work runs on its own serial queue, which opening the directory may block: the first landing in a
/// directory the OS guards waits there while the OS asks the user.
public final class DropReceiver<FileSystem: MutableTreeFileSystem>: Sendable {
    private struct Job: Sendable {
        var count: Int
        /// Every item of the offer, once read.
        var items: [OfferedItem] = []
        var next = 0
        var pull: ItemPullID?
        /// What the pull in flight reports on the readout.
        var unit: ClipboardTransferOperation.Unit?
        /// Each landed item's index, and the name it was published under.
        var landed: [(item: Int, name: Data)] = []
        var withdrawn = false
        /// The drop's readout, from the moment its first landing is ordered.
        var readout: ClipboardTransferOperation?
    }

    private let directory: String
    private let sink: ItemSinkAdapter<FileSystem>
    private let landed: @Sendable ([Data]) -> Void
    private let logger: KernovaLogger
    private let transfers: ClipboardTransferReporter
    private let peerName: String
    private let transferClock: any EngineClock
    private let queue = DispatchQueue(label: "app.kernova.drop-receiver", qos: .userInitiated)
    private let runtime = Locked<PeerAgentRuntime?>(nil)
    private let jobs = Locked<[Data: Job]>([:])

    /// A receiver landing in the directory at the absolute path `directory` through `sink`, reporting each drop
    /// to `transfers` as from `peerName`, measured on `transferClock`, and handing each drop's published names, in
    /// offer order, to `landed`.
    public init(
        directory: String, sink: ItemSinkAdapter<FileSystem>, logger: KernovaLogger,
        transfers: ClipboardTransferReporter, peerName: String,
        transferClock: any EngineClock = makePlatformEngineClock(),
        landed: @escaping @Sendable ([Data]) -> Void
    ) {
        self.directory = directory
        self.sink = sink
        self.logger = logger
        self.transfers = transfers
        self.peerName = peerName
        self.transferClock = transferClock
        self.landed = landed
    }

    /// DROP's owner, for the router `runtime` is built with.
    public var owner: ItemFeatureOwner<Void> {
        ItemFeatureOwner(
            usable: { [self] usable in
                guard usable == nil else { return }
                queue.async { [self] in connectionEnded() }
            },
            events: { [self] _, event in queue.async { [self] in handle(event) } },
            content: { _, _, _ in
                .failure(WireError(.itemRepresentationUnavailable, debugDetail: "a peer offers no drops"))
            })
    }

    /// Pulls through `runtime`, the one built with ``owner``; before it starts.
    public func attach(_ runtime: PeerAgentRuntime) {
        self.runtime.withLock { $0 = runtime }
    }

    private func handle(_ event: ItemTransferEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .offerReceived(let header):
            let token = header.token
            jobs.withLock { $0[token] = Job(count: header.count) }
            guard let runtime = runtime.withLock({ $0 }) else { return finish(token) }
            readOfferedItems(count: header.count, { runtime.readItem(token, item: $0, $1) }) { [self] items in
                queue.async { [self] in begin(token, items) }
            }
        case .offerEnded(_, .remote, let token, _):
            let idle = jobs.withLock { jobs -> Job? in
                jobs[token]?.withdrawn = true
                guard jobs[token]?.pull == nil else { return nil }
                return jobs.removeValue(forKey: token)
            }
            if let idle {
                logger.log(.notice, "The host withdrew a drop before it finished")
                interrupt(idle, of: token)
            }
        case .pullEnded(_, let id, let result):
            pullEnded(id, result)
        case .offerEnded(_, .local, _, _), .serveEnded:
            break
        }
    }

    /// Every offer of the ended connection is gone with it; one whose pull is still committing ends with it.
    private func connectionEnded() {
        let idle = jobs.withLock { jobs -> [(Data, Job)] in
            for token in jobs.keys { jobs[token]?.withdrawn = true }
            defer { jobs = jobs.filter { $0.value.pull != nil } }
            return jobs.filter { $0.value.pull == nil }.map { ($0.key, $0.value) }
        }
        for (token, job) in idle { interrupt(job, of: token) }
    }

    /// The readout's Cancel: the offer of `token` is refused `CANCELLED`, which ends its pull in flight
    /// `ITEM_OFFER_STALE`, unless it already committed.
    private func cancel(_ token: Data) {
        guard let job = jobs.withLock({ $0[token] }) else { return }
        logger.log(.notice, "The user cancelled a drop")
        job.readout?.finishCancelled(itemsOwed: .known(job.next < job.count))
        finish(token, refusing: WireError(.cancelled, debugDetail: "the user cancelled the drop"))
    }

    /// Ends `job`'s readout for the drop of `token` the host or the connection ended before it finished.
    private func interrupt(_ job: Job, of token: Data) {
        job.unit?.ended(succeeded: false)
        // A refusal is owed an answer whether or not a landing began.
        (job.readout ?? makeReadout(for: job, of: token))
            .finish(.failed(.interrupted(fileCount: job.count - job.landed.count)))
    }

    /// The readout of the drop of `token`, counting every item of `job` it will pull, and their bytes when each
    /// has an estimate; its clock starts now.
    private func makeReadout(for job: Job, of token: Data) -> ClipboardTransferOperation {
        let estimates = job.items.compactMap { Self.carried($0)?.representation.sizeEstimate }
        var expectedBytes: UInt64 = 0
        if !estimates.contains(0) {
            for estimate in estimates {
                let (sum, overflow) = expectedBytes.addingReportingOverflow(estimate)
                expectedBytes = overflow ? .max : sum
            }
        }
        return ClipboardTransferOperation(
            gesture: .drop, direction: .inbound, peerName: peerName, expectedBytes: expectedBytes,
            expectedItems: estimates.count, clock: transferClock,
            onCancelRequested: { [weak self] in
                guard let self else { return }
                queue.async { [self] in cancel(token) }
            },
            reporter: transfers)
    }

    /// The representation a drop lands of `item`, its first FILE or FOLDER one, with its index; nil when it has
    /// none, and is skipped.
    private static func carried(_ item: OfferedItem) -> (index: Int, representation: Representation)? {
        item.representations.firstIndex { [.file, .folder].contains($0.storage) }.map { ($0, item.representations[$0]) }
    }

    /// Starts landing the offer of `token` once every one of its `items` has been read, finishing it when one was
    /// not held.
    private func begin(_ token: Data, _ items: [OfferedItem]?) {
        guard let items else { return finish(token) }
        guard
            jobs.withLock({ jobs in
                guard jobs[token]?.withdrawn == false else { return false }
                jobs[token]?.items = items
                return true
            })
        else { return }
        advance(token)
    }

    /// Pulls the next item of the offer of `token`, or finishes the drop once there is none.
    private func advance(_ token: Data) {
        guard let job = jobs.withLock({ $0[token] }), !job.withdrawn else { return }
        guard job.next < job.count else { return finish(token) }
        pull(job.next, of: token)
    }

    private func pull(_ index: Int, of token: Data) {
        guard let runtime = runtime.withLock({ $0 }), let job = jobs.withLock({ $0[token] }), !job.withdrawn else {
            return
        }
        guard let (representation, offered) = Self.carried(job.items[index]) else {
            logger.log(.warning, "A dropped item offers no file or folder: it is skipped")
            return next(token)
        }
        let unmeasured: ItemPullOrder
        do throws(WireError) {
            unmeasured = try sink.order(
                token: token, item: UInt32(index), representation: UInt32(representation), byteCeiling: .max,
                landing: .staged(directory: directory, name: .keepingBoth(offered.name)))
        } catch {
            logger.log(.error, "Cannot land a drop in \(directory, privacy: .private): \(error.code, privacy: .public)")
            return finish(token, refusing: error)
        }
        let readout = job.readout ?? makeReadout(for: job, of: token)
        let unit = readout.unit(
            name: String(decoding: offered.name, as: UTF8.self), expectedBytes: offered.sizeEstimate)
        jobs.withLock { jobs in
            jobs[token]?.readout = readout
            jobs[token]?.unit = unit
        }
        let order = unmeasured.reporting(to: unit)
        runtime.pullItem(order) { [self] result in
            queue.async { [self] in
                switch result {
                case .success(let id):
                    jobs.withLock { $0[token]?.pull = id }
                case .failure(let error):
                    logger.log(.error, "A drop's pull did not open: \(error.code, privacy: .public)")
                    finish(token, refusing: error)
                }
            }
        }
    }

    private func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        guard let (token, job) = jobs.withLock({ $0.first { $0.value.pull == id } }) else { return }
        jobs.withLock { jobs in
            jobs[token]?.pull = nil
            jobs[token]?.unit = nil
        }
        if case .landed = result {
            job.unit?.ended(succeeded: true)
        } else {
            job.unit?.ended(succeeded: false)
        }
        if job.withdrawn {
            jobs.withLock { $0[token] = nil }
            interrupt(job, of: token)
            return
        }
        switch result {
        case .landed(.named(let name)):
            jobs.withLock { $0[token]?.landed.append((job.next, name)) }
            next(token)
        case .closed(.resetByPeer(let error)) where Self.unservable.contains(error.code):
            logger.log(
                .warning,
                "The host could not serve a dropped item, \(error.code, privacy: .public) errno \(error.posixErrno, privacy: .public): it is skipped"
            )
            next(token)
        case .failed(let error), .closed(.resetByPeer(let error)), .closed(.resetLocally(let error)):
            logger.log(.error, "A dropped item did not land: \(error.code, privacy: .public)")
            finish(token, refusing: error)
        case .landed(.inline), .closed:
            logger.log(.error, "A dropped item did not land: \(String(describing: result), privacy: .public)")
            finish(token, refusing: WireError(.internal, debugDetail: "\(result)"))
        }
    }

    /// The codes a host resets a pull with when it cannot produce the item, which leaves the drop's other
    /// items to land.
    private static var unservable: Set<ErrorCode> { [.readFailed, .itemRepresentationUnavailable] }

    private func next(_ token: Data) {
        jobs.withLock { $0[token]?.next += 1 }
        advance(token)
    }

    /// Releases the offer of `token`, or refuses it with `error`, and hands on what landed of it.
    private func finish(_ token: Data, refusing error: WireError? = nil) {
        guard let job = jobs.withLock({ $0.removeValue(forKey: token) }) else { return }
        job.unit?.ended(succeeded: false)
        let runtime = runtime.withLock { $0 }
        if let error {
            // A refusal is owed an answer whether or not a landing began.
            (job.readout ?? makeReadout(for: job, of: token)).finish(.failed(.transferFailed))
            runtime?.refuseOffer(token, error)
        } else {
            job.readout?.finish(.completed)
            runtime?.releaseOffer(token, endBody: DropLanded(items: job.landed.map(\.item)).endBody)
        }
        logger.log(
            .notice,
            "A drop finished: \(job.landed.count, privacy: .public) of \(job.count, privacy: .public) items landed")
        if !job.landed.isEmpty { landed(job.landed.map(\.name)) }
    }
}
#endif
