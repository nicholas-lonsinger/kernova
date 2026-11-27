import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaLogging
import KernovaTransferProgress
import KernovaWire
import Synchronization

/// The host's DROP owner: it offers what is dropped on a VM's display to the hub, which opens it on DROP's
/// console peer, serves each pull of it, and reports on the VM's transfer report how each drop ended.
///
/// A dropped file promise is called in as the drop is taken, so the offer carries an item per name its source
/// gives, and every pull of one waits for its file. Each offer ends once, whichever end ends it: the peer
/// releasing it once its items have landed or been skipped, saying how many landed, or refusing it with why it
/// could not land them, or the hub withdrawing it when DROP's console peer changes. The peer's word is the
/// only one on what landed: every other item the drop carried is reported skipped. Nothing is offered again.
package final class HubDropService: Sendable {
    /// One open offer: what serves its pulls, where its promises land, and what the drop carried.
    private struct Offer {
        let source: ClipboardOfferSource
        let peerName: String
        let promises: [CalledInFilePromise]
        let staging: URL?
        /// The drop's items the offer leaves out: gone, or not openable by this process, when it was read.
        let lost: Int
        /// When the drop was taken.
        let began: Date
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubDropService")

    private let hub = Mutex<AgentHub?>(nil)
    private let stagingRoot: ProcessStagingRoot
    /// Read and written on the main actor only; a lock because the service is shared with the hub's queue.
    private let offers = Mutex<[Data: Offer]>([:])
    /// Each pull's wait for its content, and the grant it is read under until its serve ends.
    private let serves = ClipboardServeWaits()
    private let reporter: ClipboardTransferReporter

    /// A service staging promises under `stagingRoot` and reporting to `reporter`.
    package init(stagingRoot: ProcessStagingRoot, reporter: ClipboardTransferReporter) {
        self.stagingRoot = stagingRoot
        self.reporter = reporter
    }

    /// DROP's owner, for the router `hub` is built with.
    package var owner: ItemFeatureOwner<PeerHandle> {
        ItemFeatureOwner(
            usable: { _ in },
            events: { [self] _, event in
                serves.end(by: event)
                DispatchQueue.main.async { [self] in MainActor.assumeIsolated { handle(event) } }
            },
            content: { [self] id, request, _ in content(id, request) })
    }

    /// Offers through `hub`, the one built with ``owner``.
    package func attach(_ hub: AgentHub) {
        self.hub.withLock { $0 = hub }
    }

    /// Takes a drop of `pasteboard` onto the display of the VM `peerName` names, whose promises `promises`
    /// are, as `NSPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])` returns them: each is called
    /// in now, and the drop is offered once its items are read. Whether it was taken: a drop taken that offers
    /// nothing is reported instead.
    @MainActor
    package func drop(
        _ pasteboard: any ClipboardReadPasteboard, promises receivers: [any FilePromiseReceiving], peerName: String
    ) -> Bool {
        guard let hub = hub.withLock({ $0 }) else { return false }
        let began = Date()
        reporter.gestureBegan()
        var staging: URL?
        var promises: [CalledInFilePromise] = []
        if !receivers.isEmpty {
            let directory = stagingRoot.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try stagingRoot.createDirectory(at: directory)
            } catch {
                Self.logger.log(
                    .error, "Cannot stage a dropped file promise: \(error.localizedDescription, privacy: .public)")
                report(.itemsUnreadable, to: peerName)
                return true
            }
            staging = directory
            let queue = OperationQueue()
            promises = receivers.map { CalledInFilePromise.callIn($0, into: directory, operationQueue: queue) }
        }
        Task { @MainActor [self, staging, promises] in
            let outcome = await ClipboardPasteboardReader.readDropOffer(from: pasteboard, promises: promises)
            guard case .offer(let source, let lost) = outcome else {
                release(staging, after: promises)
                return report(.itemsUnreadable, to: peerName)
            }
            if lost > 0 {
                Self.logger.log(
                    .warning,
                    "\(lost, privacy: .public) dropped item(s) were left out: gone, or not openable by this process")
            }
            let token = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            offers.withLock {
                $0[token] = Offer(
                    source: source, peerName: peerName, promises: promises, staging: staging, lost: lost,
                    began: began)
            }
            hub.offerItems(ItemOffer(token: token, items: source.items), feature: .drop) { [self] result in
                guard case .failure(let error) = result else { return }
                DispatchQueue.main.async { [self] in
                    MainActor.assumeIsolated { refused(token, error) }
                }
            }
        }
        return true
    }

    /// The hub did not open the offer of `token`, for `error`.
    @MainActor
    private func refused(_ token: Data, _ error: WireError) {
        guard let offer = offers.withLock({ $0.removeValue(forKey: token) }) else { return }
        Self.logger.log(.warning, "A drop was not offered: \(error.code, privacy: .public)")
        release(offer.staging, after: offer.promises)
        report(Self.stop(error).map { .dropStopped($0) } ?? .sendFailed, to: offer.peerName)
    }

    @MainActor
    private func handle(_ event: ItemTransferEvent) {
        guard case .offerEnded(_, .local, let token, let closure) = event,
            let offer = offers.withLock({ $0.removeValue(forKey: token) })
        else { return }
        release(offer.staging, after: offer.promises)
        let items = offer.source.items.count
        guard case .completed(let body) = closure else {
            Self.logger.log(.warning, "A drop ended before it landed: \(String(describing: closure), privacy: .public)")
            return report(Self.failure(ending: closure, items: items), to: offer.peerName)
        }
        guard let failure = Self.failure(released: body, items: items, lost: offer.lost) else {
            Self.logger.log(.notice, "A drop landed all \(items, privacy: .public) item(s)")
            return reporter.completed(startedAt: offer.began)
        }
        Self.logger.log(
            .notice,
            "A drop of \(items + offer.lost, privacy: .public) item(s) did not land whole: \(String(describing: failure), privacy: .public)"
        )
        report(failure, to: offer.peerName)
    }

    /// What a drop whose offer of `items` items, leaving `lost` out, reports once the peer released it with
    /// `body`, its `DropLanded`: nil when every item landed.
    static func failure(released body: Data, items: Int, lost: Int) -> ClipboardTransferFailure? {
        guard let landed = DropLanded(endBody: body), landed.landed <= items else { return .peerReported(.dropFailed) }
        let skipped = items + lost - landed.landed
        if landed.landed == 0 { return .itemsUnreadable }
        return skipped > 0 ? .itemsSkipped(count: skipped) : nil
    }

    /// What a drop whose offer of `items` items ended by `closure`, before the peer released it, reports.
    static func failure(ending closure: StreamClosure, items: Int) -> ClipboardTransferFailure {
        switch closure {
        case .resetByPeer(let error) where error.code == .tooLarge:
            return .tooLarge(limitBytes: Int(clamping: error.limit))
        case .resetByPeer(let error):
            return stop(error).map { .dropStopped($0) } ?? .peerReported(code(landing: error))
        case .resetLocally(let error):
            if let stop = stop(error) { return .dropStopped(stop) }
            // CANCELLED is the hub moving DROP to another console peer; the registry's other CANCELLED reset,
            // of an offer ENDed before it is whole, follows nothing a DropReceiver sends.
            return error.code == .cancelled ? .dropStopped(.movedToAnotherAgent) : .peerReported(.dropFailed)
        case .connectionClosedLocally, .connectionClosedByPeer, .connectionLost:
            return .interrupted(fileCount: items)
        case .completed:
            return .peerReported(.dropFailed)
        }
    }

    /// Why DROP was not usable, when `error` says it was not.
    static func stop(_ error: WireError) -> ClipboardDropStop? {
        switch error.code {
        case .disabledByPolicy: .turnedOff
        case .featureUnavailable where error.absence == .disabledByPolicy: .turnedOff
        case .featureUnavailable, .capabilityWithdrawn: .noAgent
        default: nil
        }
    }

    /// What a pull of an open offer is served from, on the pull's own queue: a promise waits there for its
    /// source to write it, or for the pull to end.
    private func content(_ id: ItemPullID, _ request: PullRequest) -> Result<ItemContent, WireError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let wait = serves.open(id, token: request.token) else {
            return .failure(WireError(.cancelled, debugDetail: "the pull ended before it was served"))
        }
        let serving = Task { @MainActor [self] in wait.answer(await serve(request)) }
        let answer = wait.result()
        serving.cancel()
        serves.served(id, holding: answer.access)
        return answer.content
    }

    @MainActor
    private func serve(_ request: PullRequest) async -> ClipboardServeWaits.Answer {
        guard let source = offers.withLock({ $0[request.token]?.source }) else {
            return .init(.failure(WireError(.itemOfferStale, debugDetail: "the drop is no longer offered")))
        }
        let served: ClipboardServed
        do throws(ClipboardServeError) {
            served = try await source.serve(item: Int(request.item), representation: Int(request.representation))
        } catch {
            return .init(
                .failure(
                    error == .unavailable
                        ? WireError(.itemRepresentationUnavailable, debugDetail: "the dropped item is gone")
                        : WireError(.readFailed, debugDetail: "the dropped item could not be read")))
        }
        switch served.representation {
        case .file(let url), .folder(let url):
            return .init(.success(.tree(path: url.path)), access: served.access)
        case .bytes(let data):
            return .init(.success(.inline(data)))
        }
    }

    #if DEBUG
    /// How many offers are open; tests only.
    var openOffersForTesting: Int { offers.withLock(\.count) }
    #endif

    /// The code a drop's surfaces word a peer's failure to land it with.
    static func code(landing error: WireError) -> ClipboardErrorCode {
        switch (error.code, error.posixErrno) {
        case (.writeFailed, EPERM), (.writeFailed, EACCES): .dropDownloadsDenied
        case (.diskFull, _), (.writeFailed, ENOSPC), (.writeFailed, EDQUOT): .dropDiskFull
        case (.itemUnpackRefused, _), (.itemContainerMalformed, _), (.itemDecmpfsRefused, _): .dropUnpackFailed
        default: .dropFailed
        }
    }

    @MainActor
    private func report(_ failure: ClipboardTransferFailure, to peerName: String) {
        reporter.finish(ClipboardTransferFinish(gesture: .drop, outcome: .failed(failure), peerName: peerName))
    }

    /// Removes a drop's promise staging once each file of each of its promises has landed or failed.
    @MainActor
    private func release(_ staging: URL?, after promises: [CalledInFilePromise]) {
        guard let staging else { return }
        let files = promises.flatMap(\.files)
        Task {
            for file in files { _ = try? await file.landed.value }
            do {
                try StagedItemRemoval.remove(at: staging)
            } catch {
                Self.logger.log(
                    .warning, "Cannot remove a drop's staged promises: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
