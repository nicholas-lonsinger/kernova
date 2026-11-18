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

/// A VM's clipboard: the host's ``ClipboardEnd`` over the host pasteboard, run over the guest agent's CLIPBOARD
/// items through the agent hub to the feature's console peer, with what it does reported to the VM's transfer
/// report.
///
/// One per VM, for its whole life: its owner is registered with the hub's item router before the hub exists.
@MainActor
@Observable
final class HubClipboardService {
    // MARK: - Observable state

    /// `true` while a console peer carries CLIPBOARD.
    private(set) var isConnected = false

    /// When the Mac's clipboard is offered to the guest: at every copy while passthrough is on, and otherwise only
    /// by the clipboard commands.
    private(set) var gate: ClipboardOfferGate

    /// Whether the clipboard commands do anything now: a console peer carries CLIPBOARD and passthrough is off,
    /// since with it on the clipboards are one already.
    var takesCommands: Bool { isConnected && gate == .onCommand }

    // MARK: - Wiring

    /// The host's clipboard end, both directions of it.
    @ObservationIgnored let end: ClipboardEnd<ClipboardHost>

    /// The hub whose console peer carries the clipboard; set once the hub exists, before it accepts anything.
    @ObservationIgnored var hub: AgentHub?

    /// The VM's name, for logs and reports.
    @ObservationIgnored var label: () -> String = { "VM" }

    @ObservationIgnored private let reporter: ClipboardTransferReporter
    @ObservationIgnored private let sink: ItemSinkAdapter<POSIXTreeFileSystem>
    @ObservationIgnored private var peer: PeerHandle?

    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubClipboardService")

    /// A service over `pasteboard`, offering as `gate` says, landing the guest's representations in clipboard
    /// staging under `stagingRoot` keyed `stagingKey`, its pulls built by `sink`, the hub's item sink, under the
    /// paste ceiling `maxPasteBytes` reads, reporting to `reporter`.
    init(
        pasteboard: any ClipboardPasteboard, gate: ClipboardOfferGate, sink: ItemSinkAdapter<POSIXTreeFileSystem>,
        stagingRoot: ProcessStagingRoot, stagingKey: String, maxPasteBytes: @escaping @Sendable () -> Int,
        reporter: ClipboardTransferReporter
    ) {
        self.gate = gate
        self.sink = sink
        self.reporter = reporter
        end = ClipboardEnd(
            pasteboard: pasteboard, gate: gate, stagingLabel: "host-\(stagingKey)", stagingRoot: stagingRoot,
            pasteCeiling: maxPasteBytes, logger: Self.logger)
        end.onEvent = { [weak self] in self?.heard($0) }
        end.setMayOffer(true)
    }

    /// CLIPBOARD's owner on the hub's connections.
    nonisolated func owner() -> ItemFeatureOwner<PeerHandle> {
        let end = end
        return ItemFeatureOwner(
            usable: { [weak self] peer in MainActorBridge.async { self?.setConsolePeer(peer) } },
            events: { [weak self] peer, event in
                if case .pullEnded(_, let id, let result) = event { return end.pullEnded(id, result) }
                MainActorBridge.async { self?.handle(event, from: peer) }
            },
            content: { id, request, _ in end.content(id, request) })
    }

    // MARK: - Inputs

    /// CLIPBOARD's console peer is now `peer`, or none.
    func setConsolePeer(_ peer: PeerHandle?) {
        guard peer != self.peer else { return }
        self.peer = peer
        let link = peer.flatMap(link(to:))
        isConnected = link != nil
        end.setLink(link)
        guard let peer else { return }
        Self.logger.log(
            .notice,
            "The guest agent's peer \(peer.rawValue, privacy: .public) carries the clipboard for '\(self.label(), privacy: .public)'"
        )
    }

    /// Offers as `gate` says from now on; a change ends both sides' offers.
    func setGate(_ gate: ClipboardOfferGate) {
        guard gate != self.gate else { return }
        self.gate = gate
        end.setGate(gate)
    }

    /// The paste ceiling may have risen.
    func pasteCeilingChanged() {
        end.pasteCeilingChanged()
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
        end.handle(event, on: link)
    }

    // MARK: - Reporting

    private func heard(_ event: ClipboardEndEvent) {
        if case .retracted(let retraction, let ending) = event,
            let line = ClipboardRetractionLog.line(
                retraction, of: .clipboard, on: .host(vm: label()), because: .ended(ending))
        {
            Self.logger.log(.notice, "\(line, privacy: .public)")
        }
        guard let refusal = Self.refusal(for: event) else { return }
        Self.logger.log(
            .notice,
            "Clipboard refusal for '\(self.label(), privacy: .public)': \(String(describing: refusal.failure), privacy: .public)"
        )
        // Each refusal is a gesture of its own, owed its message even when the one before raised the same.
        reporter.gestureBegan()
        reporter.finish(
            ClipboardTransferFinish(gesture: refusal.gesture, outcome: .failed(refusal.failure), peerName: label()))
    }

    /// What `event` reports to the VM's transfer report, or nil when it reports nothing. The Mac's clipboard is
    /// sent to the guest as `.forward` whether a copy or Copy to Guest offered it; the guest's arrives as `.copy`
    /// whether passthrough or Copy to Mac brought it. A read that finds the Mac's clipboard empty says so only to
    /// the command that asked for it; a retraction is logged, never reported.
    static func refusal(for event: ClipboardEndEvent)
        -> (gesture: ClipboardTransferGesture, failure: ClipboardTransferFailure)?
    {
        switch event {
        case .readEnded(_, .offered(let skipped)) where skipped > 0:
            (.forward, .itemsSkipped(count: skipped))
        case .readEnded(_, .unreadable):
            (.forward, .itemsUnreadable)
        case .readEnded(.command, .nothingToCopy):
            (.forward, .nothingToCopy)
        case .published(.writtenWithoutFiles(let count, let limitBytes)):
            (.copy, .filesLeftOut(count: count, limitBytes: limitBytes))
        case .published(.tooLarge(let limitBytes)):
            (.copy, .tooLarge(limitBytes: limitBytes))
        case .published(.writeFailed):
            (.copy, .transferFailed)
        case .requestRefused(.nothingToCopy):
            (.copy, .nothingToCopy)
        case .requestRefused(.unreadable):
            (.copy, .itemsUnreadable)
        case .requestRefused(.failed):
            (.copy, .transferFailed)
        case .pasteRefused:
            (.paste, .transferFailed)
        case .readBegan, .readEnded, .notAdmitted, .published, .retracted, .served, .landed, .pullFailed:
            nil
        }
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

    func requestOffer(_ token: Data, _ completion: @escaping @Sendable (WireError?) -> Void) {
        hub.requestClipboardOffer(token) { result in
            if case .failure(let refusal) = result { completion(refusal) } else { completion(nil) }
        }
    }

    func withdrawOffer(_ token: Data, code: ErrorCode) { hub.withdrawOffer(token, code: code, from: peer) }
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
