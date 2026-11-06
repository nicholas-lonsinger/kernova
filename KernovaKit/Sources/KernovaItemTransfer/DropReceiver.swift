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
/// Its work runs on its own serial queue, which opening the directory may block: the first landing in a
/// directory the OS guards waits there while the OS asks the user.
public final class DropReceiver<FileSystem: MutableTreeFileSystem>: Sendable {
    private struct Job: Sendable {
        var count: Int
        var next = 0
        var pull: ItemPullID?
        /// Each landed item's index, and the name it was published under.
        var landed: [(item: Int, name: Data)] = []
        var withdrawn = false
    }

    private let directory: String
    private let sink: ItemSinkAdapter<FileSystem>
    private let landed: @Sendable ([Data]) -> Void
    private let logger: KernovaLogger
    private let queue = DispatchQueue(label: "app.kernova.drop-receiver", qos: .userInitiated)
    private let runtime = Locked<PeerAgentRuntime?>(nil)
    private let jobs = Locked<[Data: Job]>([:])

    /// A receiver landing in the directory at the absolute path `directory` through `sink`, handing each
    /// drop's published names, in offer order, to `landed`.
    public init(
        directory: String, sink: ItemSinkAdapter<FileSystem>, logger: KernovaLogger,
        landed: @escaping @Sendable ([Data]) -> Void
    ) {
        self.directory = directory
        self.sink = sink
        self.logger = logger
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
            jobs.withLock { $0[header.token] = Job(count: header.count) }
            advance(header.token)
        case .offerEnded(_, .remote, let token, _):
            let idle = jobs.withLock { jobs -> Bool in
                jobs[token]?.withdrawn = true
                guard jobs[token]?.pull == nil else { return false }
                return jobs.removeValue(forKey: token) != nil
            }
            if idle { logger.log(.notice, "The host withdrew a drop before it finished") }
        case .pullEnded(_, let id, let result):
            pullEnded(id, result)
        case .offerEnded(_, .local, _, _), .serveEnded:
            break
        }
    }

    /// Every offer of the ended connection is gone with it; one whose pull is still committing ends with it.
    private func connectionEnded() {
        jobs.withLock { jobs in
            for token in jobs.keys { jobs[token]?.withdrawn = true }
            jobs = jobs.filter { $0.value.pull != nil }
        }
    }

    /// Pulls the next item of the offer of `token`, or finishes the drop once there is none.
    private func advance(_ token: Data) {
        guard let job = jobs.withLock({ $0[token] }), !job.withdrawn else { return }
        guard job.next < job.count else { return finish(token) }
        guard let runtime = runtime.withLock({ $0 }) else { return finish(token) }
        let index = job.next
        runtime.readItem(token, item: UInt32(index)) { [self] item in
            queue.async { [self] in pull(index, item, of: token) }
        }
    }

    private func pull(_ index: Int, _ item: OfferedItem?, of token: Data) {
        guard let runtime = runtime.withLock({ $0 }), let job = jobs.withLock({ $0[token] }), !job.withdrawn else {
            return
        }
        guard let item else { return finish(token) }
        guard let representation = item.representations.firstIndex(where: { [.file, .folder].contains($0.storage) })
        else {
            logger.log(.warning, "A dropped item offers no file or folder: it is skipped")
            return next(token)
        }
        let order: ItemPullOrder
        do throws(WireError) {
            order = try sink.order(
                token: token, item: UInt32(index), representation: UInt32(representation), byteCeiling: .max,
                landing: .staged(
                    directory: directory, name: .keepingBoth(item.representations[representation].name)))
        } catch {
            logger.log(.error, "Cannot land a drop in \(directory, privacy: .private): \(error.code, privacy: .public)")
            return finish(token, refusing: error)
        }
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
        jobs.withLock { $0[token]?.pull = nil }
        if job.withdrawn {
            jobs.withLock { $0[token] = nil }
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
        let runtime = runtime.withLock { $0 }
        if let error {
            runtime?.refuseOffer(token, error)
        } else {
            runtime?.releaseOffer(token, endBody: DropLanded(items: job.landed.map(\.item)).endBody)
        }
        logger.log(
            .notice,
            "A drop finished: \(job.landed.count, privacy: .public) of \(job.count, privacy: .public) items landed")
        if !job.landed.isEmpty { landed(job.landed.map(\.name)) }
    }
}
#endif
