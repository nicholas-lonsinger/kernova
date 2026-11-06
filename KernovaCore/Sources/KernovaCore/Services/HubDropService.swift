import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaWire
import Synchronization

/// The host's DROP owner: it offers what is dropped on a VM's display to the hub, which opens it on DROP's
/// console peer, serves each pull of it, and reports on the VM's transfer report how each drop ended.
///
/// A dropped file promise is called in as the drop is taken, so the offer carries an item per name its source
/// gives, and every pull of one waits for its file. Each offer ends once, whichever end ends it: the peer
/// releasing it once its items have landed or been skipped, saying which landed, or refusing it with why it
/// could not land them, or the hub withdrawing it when DROP's console peer changes. The peer's word is the
/// only one on what landed: every item the drop carried that it does not name is reported skipped. Nothing is
/// offered again.
package final class HubDropService: Sendable {
    /// One open offer: what serves its pulls, where its promises land, and what the drop carried.
    private struct Offer {
        let source: ClipboardOfferSource
        let peerName: String
        let promises: [CalledInFilePromise]
        let staging: URL?
        /// The drop's items the offer leaves out: gone or unreadable before it was read.
        let lost: Int
        /// When the drop was taken.
        let began: Date
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubDropService")

    private let hub = Mutex<AgentHub?>(nil)
    private let stagingRoot: ProcessStagingRoot
    /// Read and written on the main actor only; a lock because the service is shared with the hub's queue.
    private let offers = Mutex<[Data: Offer]>([:])
    private let reporter: ClipboardTransferReporter
    #if DEBUG
    private let stagingReleases = Mutex<[Task<Void, Never>]>([])
    #endif

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
                DispatchQueue.main.async { [self] in MainActor.assumeIsolated { handle(event) } }
            },
            content: { [self] _, request, _ in content(request) })
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
            promises = receivers.map { CalledInFilePromise.callIn($0, into: directory) }
        }
        Task { @MainActor [self, staging, promises] in
            let outcome = await ClipboardPasteboardReader.readDropOffer(from: pasteboard, promises: promises)
            guard case .offer(let source, let lost) = outcome else {
                release(staging, after: promises)
                return report(.itemsUnreadable, to: peerName)
            }
            if lost > 0 {
                Self.logger.log(
                    .warning, "\(lost, privacy: .public) dropped item(s) were gone before they were offered")
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
                    MainActor.assumeIsolated { refused(token, error, items: source.items.count) }
                }
            }
        }
        return true
    }

    /// The hub did not open the offer of `token`, for `error`.
    @MainActor
    private func refused(_ token: Data, _ error: WireError, items: Int) {
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
        guard let landed = DropLanded(endBody: body) else {
            Self.logger.log(.error, "The guest released a drop with an END body that does not decode")
            return report(.peerReported(.dropFailed), to: offer.peerName)
        }
        let landedCount = Set(landed.items).filter { offer.source.items.indices.contains($0) }.count
        let skipped = items + offer.lost - landedCount
        Self.logger.log(
            .notice,
            "A drop landed \(landedCount, privacy: .public) of \(items + offer.lost, privacy: .public) item(s)")
        if landedCount == 0 {
            report(.itemsUnreadable, to: offer.peerName)
        } else if skipped > 0 {
            report(.itemsSkipped(count: skipped), to: offer.peerName)
        } else {
            reporter.completed(.drop, startedAt: offer.began)
        }
    }

    /// What a drop whose offer of `items` items ended by `closure`, before the peer released it, reports.
    static func failure(ending closure: StreamClosure, items: Int) -> ClipboardTransferFailure {
        switch closure {
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
    /// source to write it.
    private func content(_ request: PullRequest) -> Result<ItemContent, WireError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let served = Mutex<Result<ItemContent, WireError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor [self] in
            let result = await serve(request)
            served.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return served.withLock { $0 } ?? .failure(WireError(.internal))
    }

    @MainActor
    private func serve(_ request: PullRequest) async -> Result<ItemContent, WireError> {
        guard let source = offers.withLock({ $0[request.token]?.source }) else {
            return .failure(WireError(.itemOfferStale, debugDetail: "the drop is no longer offered"))
        }
        let served: ClipboardServedRepresentation
        do throws(ClipboardServeError) {
            served = try await source.serve(item: Int(request.item), representation: Int(request.representation))
        } catch {
            return .failure(
                error == .unavailable
                    ? WireError(.itemRepresentationUnavailable, debugDetail: "the dropped item is gone")
                    : WireError(.readFailed, debugDetail: "the dropped item could not be read"))
        }
        switch served {
        case .file(let url), .folder(let url):
            return .success(.tree(path: url.path))
        case .bytes(let data):
            return .success(.inline(data))
        }
    }

    #if DEBUG
    /// How many offers are open; tests only.
    var openOffersForTesting: Int { offers.withLock(\.count) }

    /// Each removal of a drop's promise staging, in the order it was begun; tests only.
    var stagingReleasesForTesting: [Task<Void, Never>] { stagingReleases.withLock { $0 } }
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
        let removal = Task {
            for file in files { _ = try? await file.landed.value }
            do {
                try StagedItemRemoval.remove(at: staging)
            } catch {
                Self.logger.log(
                    .warning, "Cannot remove a drop's staged promises: \(String(describing: error), privacy: .public)")
            }
        }
        #if DEBUG
        stagingReleases.withLock { $0.append(removal) }
        #else
        _ = removal
        #endif
    }
}
