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
/// The guest's offer is taken only while passthrough runs, which writes it to the Mac; one arriving otherwise
/// crossed passthrough stopping, and is let go unwritten.
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

    /// Whether passthrough runs: a guest offer is taken only while it does.
    @ObservationIgnored var passthroughRuns: () -> Bool = { false }

    /// The host pasteboard's change count now.
    @ObservationIgnored var hostPasteboardChangeCount: () -> Int = { 0 }

    /// Whether passthrough holds a Mac copy it has yet to offer, and asks it to offer that copy now: what a guest
    /// offer crossing it loses to.
    @ObservationIgnored var passthroughHoldsUnsentCopy: () -> Bool = { false }
    @ObservationIgnored var passthroughForwardNow: () -> Void = {}

    /// Bumped each time a console peer is named, so passthrough sees a new connection however fast the last
    /// one went.
    private(set) var connectionEpoch: UInt64 = 0

    /// The host pasteboard's change count when the console peer now up was named, after the last one's
    /// retraction: a Mac copy since is one made while this connection was up.
    @ObservationIgnored private(set) var connectionStartChangeCount: Int?

    @ObservationIgnored private let sink: ItemSinkAdapter<POSIXTreeFileSystem>
    @ObservationIgnored private var peer: PeerHandle?

    /// The guest's offer, while it is the host's clipboard.
    @ObservationIgnored private var remote: ClipboardRemoteOffer?

    /// Where a file promise copied on the Mac is called in when passthrough's offer of it is pulled.
    @ObservationIgnored private let promiseStaging: ClipboardFileStaging
    /// Where a snapshot of the Mac's clipboard calls its file promises in, each into a lease of its own.
    @ObservationIgnored let snapshotStaging: ClipboardFileStaging?
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
        snapshotStaging = .leased(label: "host-copies-\(stagingKey)", root: stagingRoot)
        exchange.onRemoteOffer = { [weak self] in self?.received($0) }
        exchange.onRemoteOfferEnded = { [weak self] in self?.remoteEnded($0, $1) }
        exchange.holdsUnsentCopy = { [weak self] in self?.passthroughHoldsUnsentCopy() ?? false }
        exchange.onCrossingRefused = { [weak self] in self?.passthroughForwardNow() }
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

    /// CLIPBOARD's console peer is now `peer`, or none. A new connection starts where the Mac's clipboard stands
    /// once the last one's retraction is done: neither side is sent what its clipboard already holds.
    func setConsolePeer(_ peer: PeerHandle?) {
        guard peer != self.peer else { return }
        self.peer = peer
        isConnected = peer != nil
        exchange.setLink(peer.flatMap(link(to:)))
        guard let peer else {
            connectionStartChangeCount = nil
            return
        }
        connectionEpoch &+= 1
        connectionStartChangeCount = hostPasteboardChangeCount()
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

    /// Nothing to stop: the hub's connections end with the session, and every offer with its connection.
    func stop() {}

    /// Passthrough stopped, and both ends' passthrough offers end with it: the host's offer, which only
    /// passthrough makes, is withdrawn, so the guest retracts its write of it; the guest's offer is let go, and
    /// the Mac's write of it retracted as at a link's end, what it wrote as data kept and its promises gone.
    /// Nothing crosses after that but a command: the guest offers nothing while passthrough is off.
    func passthroughStopped() {
        exchange.withdrawLocal()
        guard let remote else { return }
        self.remote = nil
        exchange.release(remote)
        guard retractHostWrite(remote.token) != nil else { return }
        Self.logger.log(
            .notice,
            "Retracted the guest's clipboard from the host pasteboard for '\(self.label(), privacy: .public)': passthrough stopped"
        )
    }

    /// Makes the Mac's copy the host's clipboard and offers it: a new connection is offered only a copy made
    /// after it, so nothing is owed a retry.
    func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome {
        exchange.offer(copy)
        return .settled
    }

    /// The Mac's pasteboard changed to something it offers nothing of: the host's offer is withdrawn, and the
    /// guest's clipboard is left as it is.
    func hostCopyOffersNothing() {
        exchange.withdrawLocal()
    }

    var clipboardConnection: ClipboardConnectionID? { exchange.connection }

    // MARK: - The clipboard commands

    /// Sends `snapshot` to the guest as a copy, served until the guest releases it, its write replaced.
    func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? {
        exchange.sendCopy(snapshot) ? nil : .transferFailed
    }

    /// Asks the guest for its clipboard, lands every representation of its copy but a file or folder, and has
    /// `write` write it unless a newer copy arrived first.
    func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
        let answer = await withCheckedContinuation { continuation in
            exchange.askForCopy { continuation.resume(returning: $0) }
        }
        switch answer {
        case .nothing:
            return .nothing
        case .failed(let error):
            Self.logger.log(
                .notice, "The guest's clipboard was not copied: \(String(describing: error), privacy: .public)")
            return .failed(Self.failure(error))
        case .copy(let copy):
            let exchange = exchange
            let landing = await exchange.land(copy) { leftOut in
                write(
                    GuestCopyContents(
                        serving: copy.serving, items: copy.items, concealed: copy.concealed,
                        plan: ClipboardPromisePolicy.copyPlan(copy.items, room: copy.pasteRoom),
                        held: { copy.held(item: $0, representation: $1) }, puller: copy,
                        referencesLeftOut: leftOut, release: { exchange.releaseCopy(copy) }))
            }
            switch landing {
            case .written: return .landed
            case .alreadyHeld: return .alreadyHeld
            case .superseded: return .failed(.transferFailed)
            case .failed(let error): return .failed(Self.failure(error))
            }
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

    /// The guest refused `copy` of the Mac's clipboard, or wrote it without some of it. A copy only naming what
    /// the guest's clipboard holds already, and one a newer copy superseded, are the user's to make again: nothing
    /// is said.
    private func copyRefused(_ copy: ClipboardOfferSource, _ error: WireError) {
        Self.logger.log(
            .notice, "The guest refused the Mac's clipboard copy: \(String(describing: error), privacy: .public)")
        switch error.code {
        case .clipboardAlreadyHeld, .itemOfferReplaced:
            return
        case .clipboardFilesWithheld:
            reportRefusal(
                gesture: .send,
                .filesLeftOut(
                    count: ClipboardPromisePolicy.fileCount(copy.items), limitBytes: Int(clamping: error.limit)))
        default:
            reportRefusal(gesture: .send, Self.failure(error))
        }
    }

    /// The failure a copy ending with `error` reports.
    private static func failure(_ error: WireError) -> ClipboardTransferFailure {
        switch error.code {
        case .clipboardChanged: .clipboardChanged
        case .clipboardPartsGone: .partsGone
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
                        serving: remote.serving, items: remote.items, concealed: remote.concealed,
                        servingFileURLs: servingFileURLs, puller: remote)))
        }
        return items
    }

    // MARK: - The guest's offer

    /// Takes the guest's offer for passthrough to write, or — passthrough having stopped as it crossed — lets
    /// it go unwritten.
    private func received(_ remote: ClipboardRemoteOffer) {
        guard passthroughRuns() else {
            Self.logger.log(
                .notice,
                "Let the guest's clipboard offer go for '\(self.label(), privacy: .public)': passthrough is off")
            exchange.release(remote)
            return
        }
        self.remote = remote
        inboundOfferSeq &+= 1
    }

    /// The guest's offer stopped being the host's clipboard. A write of it the host pasteboard still holds is
    /// retracted, since nothing more of it can be pulled; a Mac copy that replaced it already replaced the
    /// write. Passthrough made the write and runs still, so nothing is reported.
    ///
    /// - The guest ended it: its clipboard moved on.
    /// - A Mac copy replaced it: the guest's clipboard is that copy now.
    /// - The connection left: the guest may hold it still; the next connection carries only its next copy.
    private func remoteEnded(_ remote: ClipboardRemoteOffer, _ ending: ClipboardItemExchange.RemoteEnding) {
        guard self.remote === remote else { return }
        self.remote = nil
        let why: String
        switch ending {
        case .superseded: return
        case .linkLost: why = "the guest's connection ended"
        case .byFarSide: why = "the guest's clipboard moved on"
        }
        guard retractHostWrite(remote.token) != nil else { return }
        Self.logger.log(
            .notice,
            "Retracted the guest's clipboard from the host pasteboard for '\(self.label(), privacy: .public)': \(why, privacy: .public)"
        )
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
