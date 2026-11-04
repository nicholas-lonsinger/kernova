import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// A VM's clipboard over the guest agent's CLIPBOARD items, through the agent hub to the feature's console
/// peer: the host's offer of a copy on the Mac passthrough read from its pasteboard, the guest's offer, and the
/// copies the clipboard commands send each way.
///
/// One per VM, for its whole life: its owner is registered with the hub's item router before the hub exists.
/// The guest's offer stays held while it is the host's clipboard, whether or not passthrough wrote it to the
/// Mac, so turning passthrough on can publish it.
@MainActor
@Observable
final class HubClipboardService: ClipboardServicing {
    // MARK: - Observable state

    /// `true` while a console peer carries CLIPBOARD.
    private(set) var isConnected = false

    var supportsBinaryRepresentations: Bool { true }

    /// Bumped once per guest offer taken.
    private(set) var inboundOfferSeq: UInt64 = 0

    // MARK: - Wiring

    /// The exchange both directions run through.
    @ObservationIgnored let exchange: ClipboardItemExchange

    /// The hub whose console peer carries the clipboard; set once the hub exists, before it accepts anything.
    @ObservationIgnored var hub: AgentHub?

    /// The VM's name, for logs and reports.
    @ObservationIgnored var label: () -> String = { "VM" }

    /// This VM's transfer report.
    @ObservationIgnored var reporter: ClipboardTransferReporter?

    /// The paste ceiling in force: what the exchange's pulls read, from any thread.
    @ObservationIgnored let maxPasteBytes: @Sendable () -> Int

    /// Withdraws the promises of this VM's write serving the offer named, if the host pasteboard still holds
    /// it, returning what that left: what an offer's end owes a write of it.
    @ObservationIgnored var retractHostWrite: (_ servingOffer: Data) -> ClipboardRetraction? = { _ in nil }

    /// Whether passthrough runs: it decides only whether a retraction is reported.
    @ObservationIgnored var passthroughRuns: () -> Bool = { false }

    /// The host pasteboard's change count now.
    @ObservationIgnored var hostPasteboardChangeCount: () -> Int = { 0 }

    /// Whether passthrough holds a Mac copy it has yet to offer, and asks it to offer that copy now: what a guest
    /// offer crossing it loses to.
    @ObservationIgnored var passthroughHoldsUnsentCopy: () -> Bool = { false }
    @ObservationIgnored var passthroughForwardNow: () -> Void = {}
    /// Asks passthrough to offer the Mac's copy again on the new connection: the guest lost it with the last.
    @ObservationIgnored var passthroughReofferAfterReturn: () -> Void = {}

    /// The host pasteboard's change count when the last connection ended, after its retraction.
    @ObservationIgnored private(set) var changeCountAtLinkLoss: Int?

    /// Whether the host's own offer was the clipboard when the last connection ended.
    @ObservationIgnored private var hostOfferLostWithLink = false

    /// The host pasteboard's change count when this clipboard last changed — the guest's offer taken, or the
    /// host's offered — so a Mac copy since it reads as newer than both.
    @ObservationIgnored private(set) var clipboardChangeMark: Int?

    /// Bumped each time a console peer is named, so passthrough sees a new connection however fast the last
    /// one went.
    private(set) var connectionEpoch: UInt64 = 0

    @ObservationIgnored private let sink: ItemSinkAdapter<POSIXTreeFileSystem>
    @ObservationIgnored private var peer: PeerHandle?

    /// The guest's offer, while it is the host's clipboard.
    @ObservationIgnored private var remote: ClipboardRemoteOffer?

    /// Where a file promise copied on the Mac is called in.
    @ObservationIgnored private let promiseStaging: ClipboardFileStaging
    @ObservationIgnored private var nextPromiseGeneration: UInt64 = 1

    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubClipboardService")

    /// A service landing the guest's representations in clipboard staging under `stagingRoot`, keyed
    /// `stagingKey`, its pulls built by `sink`, the hub's item sink, under the paste ceiling `maxPasteBytes` reads.
    init(
        sink: ItemSinkAdapter<POSIXTreeFileSystem>, stagingRoot: ProcessStagingRoot, stagingKey: String,
        maxPasteBytes: @escaping @Sendable () -> Int
    ) {
        self.sink = sink
        self.maxPasteBytes = maxPasteBytes
        exchange = ClipboardItemExchange(
            side: .host, stagingLabel: "host-\(stagingKey)", stagingRoot: stagingRoot, pasteCeiling: maxPasteBytes,
            logger: Self.logger)
        promiseStaging = ClipboardFileStaging(label: "host-promises-\(stagingKey)", root: stagingRoot)
        exchange.onRemoteOffer = { [weak self] in self?.received($0) }
        exchange.onRemoteOfferEnded = { [weak self] in self?.remoteEnded($0, $1) }
        exchange.holdsUnsentCopy = { [weak self] in self?.passthroughHoldsUnsentCopy() ?? false }
        exchange.onCrossingRefused = { [weak self] in self?.passthroughForwardNow() }
        exchange.onEmptyUnchangedReturn = { [weak self] in self?.emptyUnchangedReturn() }
        exchange.onCopyEnded = { [weak self] in self?.copyEnded($0) }
        exchange.onCopyRefused = { [weak self] in self?.copyRefused($0, $1) }
    }

    /// CLIPBOARD's owner on the hub's connections.
    nonisolated func owner() -> ItemFeatureOwner<PeerHandle> {
        let exchange = exchange
        return ItemFeatureOwner(
            usable: { [weak self] peer in MainActorBridge.async { self?.setConsolePeer(peer) } },
            events: { [weak self] peer, event in
                if case .pullEnded(_, let id, let result) = event { return exchange.pullEnded(id, result) }
                MainActorBridge.async { self?.handle(event, from: peer) }
            },
            content: { exchange.content($0, $1, $2) })
    }

    // MARK: - The console peer

    /// CLIPBOARD's console peer is now `peer`, or none. The connection ending records where the Mac's clipboard
    /// stood once its retraction was done, so the next one is offered only a Mac copy made since.
    func setConsolePeer(_ peer: PeerHandle?) {
        guard peer != self.peer else { return }
        let ended = self.peer != nil
        if ended { hostOfferLostWithLink = exchange.localOfferStood }
        self.peer = peer
        isConnected = peer != nil
        exchange.setLink(peer.flatMap(link(to:)))
        if ended { changeCountAtLinkLoss = hostPasteboardChangeCount() }
        guard let peer else { return }
        connectionEpoch &+= 1
        Self.logger.log(
            .notice,
            "The guest agent's peer \(peer.rawValue, privacy: .public) carries the clipboard for '\(self.label(), privacy: .public)'"
        )
    }

    private func link(to peer: PeerHandle) -> HubClipboardLink? {
        guard let hub else {
            assertionFailure("a console peer before the hub was set")
            return nil
        }
        return HubClipboardLink(hub: hub, peer: peer, sink: sink)
    }

    private func handle(_ event: ItemTransferEvent, from peer: PeerHandle) {
        guard let link = link(to: peer) else { return }
        exchange.handle(event, on: link)
    }

    // MARK: - ClipboardServicing

    /// Nothing to stop: the hub's connections end with the session, and the host's offer outlives it, for the
    /// next console peer.
    func stop() {}

    /// Makes the Mac's copy the host's clipboard and offers it: a new connection is passthrough's to offer again,
    /// so nothing is owed a retry.
    func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome {
        exchange.offer(copy)
        clipboardChangeMark = hostPasteboardChangeCount()
        return .settled
    }

    /// The Mac's pasteboard changed to something it offers nothing of: the host's offer is withdrawn, and the
    /// guest's clipboard is left as it is.
    func hostCopyOffersNothing() {
        exchange.withdrawLocal()
    }

    var resolvesCrossings: Bool { true }

    var hasStandingGuestOffer: Bool { remote?.isOpen == true && exchange.remote === remote }

    /// The guest's first offer on a new connection reported an empty clipboard unchanged since the last: it lost
    /// the host's copy with that connection, so passthrough offers it again.
    private func emptyUnchangedReturn() {
        guard hostOfferLostWithLink else { return }
        hostOfferLostWithLink = false
        passthroughReofferAfterReturn()
    }

    // MARK: - The clipboard commands

    /// Sends `snapshot` to the guest as a copy, served until the guest's clipboard lets it go.
    func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? {
        exchange.sendCopy(snapshot) ? nil : .transferFailed
    }

    var guestOfferToken: Data? { exchange.remote?.token }

    /// Asks the guest for its clipboard, and lands every representation of its copy but a file or folder.
    func guestClipboardCopy() async -> GuestClipboardCopy {
        let answer = await withCheckedContinuation { continuation in
            exchange.askForCopy { continuation.resume(returning: $0) }
        }
        switch answer {
        case .nothing:
            return .nothing
        case .alreadyHeld:
            return .alreadyHeld
        case .failed(let error):
            Self.logger.log(
                .notice, "The guest's clipboard was not copied: \(String(describing: error), privacy: .public)")
            return .failed(Self.failure(error))
        case .copy(let copy):
            if let error = await copy.landInline() {
                exchange.refuseCopy(copy, error)
                return .failed(Self.failure(error))
            }
            let exchange = exchange
            return .copy(
                GuestCopyContents(
                    token: copy.token, items: copy.items, concealed: copy.concealed,
                    plan: ClipboardPromisePolicy.copyPlan(copy.items, room: copy.pasteRoom),
                    landed: { copy.landedBytes(item: $0, representation: $1) }, puller: copy,
                    release: { exchange.releaseCopy(copy) }))
        }
    }

    /// A copy the guest sent ended with the connection: what the Mac's clipboard holds of it is retracted, its
    /// files being on the guest's disk.
    private func copyEnded(_ copy: ClipboardRemoteOffer) {
        guard let retraction = retractHostWrite(copy.token) else { return }
        Self.logger.log(
            .notice,
            "Retracted the guest's copied files from the host pasteboard for '\(self.label(), privacy: .public)': the guest's connection ended"
        )
        reportRefusal(
            gesture: .copy, retraction == .keptData ? .disconnectedFilesRetracted : .disconnectedCopyRetracted)
    }

    /// The guest refused `copy` of the Mac's clipboard, or wrote it without its files.
    private func copyRefused(_ copy: ClipboardOfferSource, _ error: WireError) {
        Self.logger.log(
            .notice, "The guest refused the Mac's clipboard copy: \(String(describing: error), privacy: .public)")
        guard error.code == .clipboardFilesWithheld else { return reportRefusal(gesture: .send, Self.failure(error)) }
        reportRefusal(
            gesture: .send,
            .filesLeftOut(
                count: ClipboardPromisePolicy.fileCount(copy.items), limitBytes: Int(clamping: error.limit)))
    }

    /// The failure a copy ending with `error` reports.
    private static func failure(_ error: WireError) -> ClipboardTransferFailure {
        switch error.code {
        case .clipboardChanged: .clipboardChanged
        case .tooLarge: .tooLarge(limitBytes: Int(clamping: error.limit))
        default: .transferFailed
        }
    }

    func reservePromiseDestination() -> URL? {
        let generation = nextPromiseGeneration
        nextPromiseGeneration += 1
        do {
            return try promiseStaging.reserveScratchDirectory(generation: generation)
        } catch {
            Self.logger.log(
                .error,
                "Failed to reserve a clipboard promise directory for '\(self.label(), privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// The guest's live offer, whole. A file set over the paste ceiling is offered without its file URLs, each
    /// withheld one reported dropped.
    func guestClipboardItems() -> [CopyToMacItem] {
        guard let remote, remote.isOpen else { return [] }
        let ceiling = maxPasteBytes()
        let budget = ClipboardPromisePolicy.pasteBudget(remote.items, limit: ceiling)
        var items: [CopyToMacItem] = []
        if budget.exceeds {
            Self.logger.log(
                .warning,
                "Refused the guest's files: they total \(budget.total, privacy: .public) bytes, over the \(ceiling, privacy: .public)-byte cap"
            )
            reportRefusal(gesture: .copy, .tooLarge(limitBytes: ceiling))
            for item in remote.items {
                for promised in ClipboardPromisePolicy.promisedTypes(for: item) where promised.isFileURL {
                    items.append(.droppedFile(.overPasteBudget))
                }
            }
        }
        let servingFileURLs = !budget.exceeds
        if remote.items.contains(where: {
            !ClipboardPromisePolicy.promisedTypes(for: $0, servingFileURLs: servingFileURLs).isEmpty
        }) {
            items.append(
                .offer(
                    CopyToMacOffer(
                        token: remote.token, items: remote.items, concealed: remote.concealed,
                        servingFileURLs: servingFileURLs, puller: remote)))
        }
        return items
    }

    // MARK: - The guest's offer

    private func received(_ remote: ClipboardRemoteOffer) {
        self.remote = remote
        clipboardChangeMark = hostPasteboardChangeCount()
        inboundOfferSeq &+= 1
    }

    /// The guest's offer stopped being the host's clipboard. A write of it the host pasteboard still holds is
    /// retracted, since nothing more of it can be pulled; a Mac copy that replaced it already replaced the
    /// write. A retraction is reported only with passthrough off, where it took away a copy passthrough made
    /// while it ran.
    ///
    /// - The guest ended it: its clipboard moved on.
    /// - A Mac copy replaced it: the guest's clipboard is that copy now.
    /// - The connection left: the guest may hold it still, and its return re-offers it.
    private func remoteEnded(_ remote: ClipboardRemoteOffer, _ ending: ClipboardItemExchange.RemoteEnding) {
        guard self.remote === remote else { return }
        self.remote = nil
        switch ending {
        case .superseded:
            return
        case .linkLost:
            guard retractHostWrite(remote.token) != nil else { return }
            Self.logger.log(
                .notice,
                "Retracted the host-pasteboard promise for '\(self.label(), privacy: .public)': the guest's connection ended"
            )
            if !passthroughRuns() { reportRefusal(gesture: .copy, .disconnectedCopyRetracted) }
        case .byFarSide(let hasSuccessor):
            guard retractHostWrite(remote.token) != nil else { return }
            Self.logger.log(
                .notice,
                "Retracted the stale host-pasteboard promise for '\(self.label(), privacy: .public)': the guest's clipboard moved on"
            )
            if !passthroughRuns() {
                reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: hasSuccessor))
            }
        }
    }

    private func reportRefusal(gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure) {
        reporter?.finish(ClipboardTransferFinish(gesture: gesture, outcome: .failed(failure), peerName: label()))
    }
}

/// CLIPBOARD's calls through the hub to one peer.
struct HubClipboardLink: ClipboardItemLink {
    let hub: AgentHub
    let peer: PeerHandle
    let sink: ItemSinkAdapter<POSIXTreeFileSystem>

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        hub.offerItems(offer, feature: .clipboard) { result in
            if case .failure(let refusal) = result { completion(refusal) } else { completion(nil) }
        }
    }

    func withdrawOffer(_ token: Data) { hub.withdrawOffer(token, from: peer) }
    func releaseOffer(_ token: Data) { hub.releaseOffer(token, of: peer) }
    func refuseOffer(_ token: Data, _ error: WireError) { hub.refuseOffer(token, error, of: peer) }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        hub.readItem(token, item: item, of: peer, completion)
    }

    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void) {
        hub.pullItem(order, from: peer, completion)
    }

    func cancelPull(_ id: ItemPullID) { hub.cancelPull(id, on: peer) }

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder {
        try sink.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
    }
}
