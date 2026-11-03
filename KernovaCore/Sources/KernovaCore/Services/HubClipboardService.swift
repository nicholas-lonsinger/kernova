import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaLogging
import KernovaWire
import UniformTypeIdentifiers

/// A VM's clipboard over the guest agent's CLIPBOARD items, through the agent hub to the feature's console
/// peer: the buffer the clipboard window and passthrough read and write, the host's offer the buffer makes, and
/// the guest's offer shown in it.
///
/// One per VM, for its whole life: its owner is registered with the hub's item router before the hub exists,
/// and each console peer the hub names is offered the host's clipboard again. The guest's offer stays held
/// while the buffer shows it or the host pasteboard holds this VM's write; once neither does, it is released.
@MainActor
@Observable
final class HubClipboardService: ClipboardServicing {
    // MARK: - Observable state

    /// The buffer. A change that leaves the guest's offer shown nowhere releases it, once the host pasteboard
    /// no longer holds this VM's write either.
    var clipboardContent: ClipboardContent = .empty {
        didSet { releaseRemoteIfUnheld() }
    }

    /// `true` while a console peer carries CLIPBOARD.
    private(set) var isConnected = false

    var supportsBinaryRepresentations: Bool { true }

    /// Bumped once per guest offer shown in the buffer, never by its preview's pulls.
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

    /// The paste ceiling in force.
    @ObservationIgnored var maxPasteBytes: () -> Int = { ClipboardPasteLimit.defaultBytes }

    /// Whether the host pasteboard still holds this VM's most recent write.
    @ObservationIgnored var hostPasteboardHoldsOurWrite: () -> Bool = { false }

    /// Retracts this VM's promised write from the host pasteboard if it still holds it, returning whether it
    /// did: what the guest's clipboard moving on owes a Copy to Mac whose offer has ended.
    @ObservationIgnored var retractStaleHostWrite: () -> Bool = { false }

    @ObservationIgnored private let sink: ItemSinkAdapter<POSIXTreeFileSystem>
    @ObservationIgnored private var peer: PeerHandle?

    /// The guest's offer, while the buffer or the host pasteboard may still need it.
    @ObservationIgnored private var remote: ClipboardRemoteOffer?

    /// The digest of the buffer as the guest's offer last set it: once the buffer's differs, the user has
    /// replaced what it showed.
    @ObservationIgnored private var remoteDigest: Data?

    /// The digest of the buffer last offered to the guest, or shown from it.
    @ObservationIgnored private var offeredDigest: Data?

    /// The guest offer whose preview has run, by token.
    @ObservationIgnored private var previewedToken: Data?

    /// Where the window materializes a dropped file promise.
    @ObservationIgnored private let dropStaging: ClipboardFileStaging
    @ObservationIgnored private var nextDropGeneration: UInt64 = 1

    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubClipboardService")

    /// A service landing the guest's files in clipboard staging under `stagingRoot`, keyed `stagingKey`, its
    /// pulls built by `sink`, the hub's item sink.
    init(sink: ItemSinkAdapter<POSIXTreeFileSystem>, stagingRoot: ProcessStagingRoot, stagingKey: String) {
        self.sink = sink
        exchange = ClipboardItemExchange(
            stagingLabel: "host-\(stagingKey)", stagingRoot: stagingRoot,
            pasteCeiling: ClipboardPasteLimit.defaultBytes,
            logger: Self.logger)
        dropStaging = ClipboardFileStaging(label: "host-drops-\(stagingKey)", root: stagingRoot)
        exchange.onRemoteOffer = { [weak self] in self?.received($0) }
        exchange.onRemoteOfferEnded = { [weak self] in self?.remoteEnded($0, byGuest: $1) }
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
            content: { exchange.content($0, $1) })
    }

    // MARK: - The console peer

    /// CLIPBOARD's console peer is now `peer`, or none: a new one is offered the host's clipboard again.
    func setConsolePeer(_ peer: PeerHandle?) {
        guard peer != self.peer else { return }
        self.peer = peer
        isConnected = peer != nil
        exchange.setLink(peer.flatMap(link(to:)))
        guard let peer else { return }
        Self.logger.log(
            .notice,
            "The guest agent's peer \(peer.rawValue, privacy: .public) carries the clipboard for '\(self.label(), privacy: .public)'"
        )
        exchange.reofferLocal()
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

    /// Nothing to stop: the hub's connections end with the session, and the buffer and the host's offer outlive
    /// it, for the next console peer.
    func stop() {}

    func grabIfChanged() -> ClipboardGrabOutcome {
        guard !clipboardContent.isEmpty else { return .settled }
        // A placeholder has no bytes to serve, and is the guest's own content.
        guard !clipboardContent.representations.contains(where: \.isPendingRemote) else { return .settled }
        let digest = clipboardContent.digest
        guard digest != offeredDigest else { return .settled }
        offeredDigest = digest
        // Held and offered to every console peer from now on, so nothing is owed a retry.
        exchange.offer(ClipboardOfferSource(content: clipboardContent))
        return .settled
    }

    func clearBuffer() {
        offeredDigest = nil
        clipboardContent = .empty
    }

    func reserveDropDestination() -> URL? {
        let generation = nextDropGeneration
        nextDropGeneration += 1
        do {
            return try dropStaging.reserveScratchDirectory(generation: generation)
        } catch {
            Self.logger.log(
                .error,
                "Failed to reserve a clipboard drop directory for '\(self.label(), privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Pulls, for the window to render, each INLINE representation of the guest's offer it renders richly, each
    /// no larger than the window's limit for its kind. Once per offer; never for concealed content.
    func materializeForPreview() async {
        guard let remote, remote.isOpen, !remote.concealed, clipboardContent.digest == remoteDigest,
            previewedToken != remote.token
        else { return }
        previewedToken = remote.token
        var pulled: [ItemRepresentation: Data] = [:]
        for (item, offered) in remote.items.enumerated() {
            for (index, representation) in offered.representations.enumerated() {
                guard let ceiling = Self.previewCeiling(representation) else { continue }
                if let data = await remote.previewBytes(item: item, representation: index, byteCeiling: ceiling) {
                    pulled[ItemRepresentation(item: item, representation: index)] = data
                }
                guard self.remote === remote else { return }
            }
        }
        guard !pulled.isEmpty, self.remote === remote, clipboardContent.digest == remoteDigest else { return }
        show(Self.content(of: remote, pulled: pulled))
    }

    /// The guest's live offer, whole, when the buffer still shows it; the buffer's own content otherwise. A file
    /// set over the paste ceiling is offered without its file URLs, each withheld one reported dropped.
    func materializeForCopy() -> [CopyToMacItem] {
        guard let remote, remote.isOpen, clipboardContent.digest == remoteDigest else {
            let reps = clipboardContent.representations.filter { !$0.isPendingRemote }
            return reps.map { .resolved($0) }
        }
        let ceiling = maxPasteBytes()
        exchange.setPasteCeiling(ceiling)
        let budget = ClipboardPromisePolicy.pasteBudget(remote.items, limit: ceiling)
        var items: [CopyToMacItem] = []
        if budget.exceeds {
            Self.logger.log(
                .warning,
                "Copy-to-Mac refused the files: they total \(budget.total, privacy: .public) bytes, over the \(ceiling, privacy: .public)-byte cap"
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
                        items: remote.items, concealed: remote.concealed, servingFileURLs: servingFileURLs,
                        puller: remote)))
        }
        return items
    }

    // MARK: - The guest's offer

    private func received(_ remote: ClipboardRemoteOffer) {
        self.remote = remote
        previewedToken = nil
        show(ClipboardContent(previewOf: remote.items, concealed: remote.concealed))
        inboundOfferSeq &+= 1
    }

    /// Shows `content` from the guest's offer: never offered back, and the mark edits are told apart by.
    private func show(_ content: ClipboardContent) {
        remoteDigest = content.digest
        offeredDigest = content.digest
        clipboardContent = content
    }

    /// The guest's offer ended. When the guest's clipboard moved on, a Copy to Mac still standing for it is
    /// retracted; the buffer keeps what it shows either way.
    private func remoteEnded(_ remote: ClipboardRemoteOffer, byGuest: Bool) {
        guard self.remote === remote else { return }
        self.remote = nil
        previewedToken = nil
        guard byGuest, retractStaleHostWrite() else { return }
        reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: true))
        Self.logger.log(
            .notice,
            "Retracted the stale host-pasteboard promise for '\(self.label(), privacy: .public)': the guest's clipboard moved on"
        )
    }

    /// Releases the guest's offer once the buffer no longer shows it and the host pasteboard no longer holds
    /// this VM's write.
    private func releaseRemoteIfUnheld() {
        guard let remote, clipboardContent.digest != remoteDigest, !hostPasteboardHoldsOurWrite() else { return }
        self.remote = nil
        remoteDigest = nil
        previewedToken = nil
        exchange.release(remote)
    }

    private func reportRefusal(gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure) {
        reporter?.finish(ClipboardTransferFinish(gesture: gesture, outcome: .failed(failure), peerName: label()))
    }

    // MARK: - Preview

    private struct ItemRepresentation: Hashable {
        var item: Int
        var representation: Int
    }

    /// The most bytes the window's preview pulls of `representation`, or nil when it renders none of it: text
    /// within the editor's limit, and rich text or an image within the preview's.
    private static func previewCeiling(_ representation: Representation) -> UInt64? {
        guard representation.storage == .inline, ClipboardPromisePolicy.keeps(representation),
            let uti = representation.type.appleUTI
        else { return nil }
        let type = UTType(uti)
        if type?.conforms(to: .image) == true || type?.conformsToRTFFamily == true {
            return UInt64(ClipboardPreviewPolicy.maxEagerPreviewBytes)
        }
        if uti == ClipboardContent.utf8TextUTI || type?.conforms(to: .text) == true {
            return UInt64(ClipboardPreviewPolicy.maxEditableTextBytes)
        }
        return nil
    }

    /// `remote`'s items as ``ClipboardContent/init(previewOf:concealed:)`` shows them, each representation in
    /// `pulled` holding its bytes: a file item by its image's.
    private static func content(of remote: ClipboardRemoteOffer, pulled: [ItemRepresentation: Data]) -> ClipboardContent
    {
        var representations: [ClipboardContent.Representation] = []
        for (item, offered) in remote.items.enumerated() {
            let kept = offered.representations.enumerated().filter { ClipboardPromisePolicy.keeps($0.element) }
            if let file = kept.first(where: { $0.element.storage != .inline }) {
                let name = String(decoding: file.element.name, as: UTF8.self)
                let image = kept.first { pulled[ItemRepresentation(item: item, representation: $0.offset)] != nil }
                if let image, let uti = image.element.type.appleUTI,
                    let data = pulled[ItemRepresentation(item: item, representation: image.offset)]
                {
                    representations.append(ClipboardContent.Representation(uti: uti, data: data, filename: name))
                } else {
                    representations.append(
                        ClipboardContent.Representation(
                            pendingRemoteUTI: file.element.type.appleUTI
                                ?? (file.element.storage == .folder ? UTType.folder : UTType.data).identifier,
                            byteCount: Int(clamping: file.element.sizeEstimate), filename: name,
                            isDirectory: file.element.storage == .folder))
                }
                continue
            }
            for (index, inline) in kept {
                guard let uti = inline.type.appleUTI else { continue }
                if let data = pulled[ItemRepresentation(item: item, representation: index)] {
                    representations.append(ClipboardContent.Representation(uti: uti, data: data))
                } else {
                    representations.append(
                        ClipboardContent.Representation(
                            pendingRemoteUTI: uti, byteCount: Int(clamping: inline.sizeEstimate)))
                }
            }
        }
        return ClipboardContent(representations: representations, isConcealed: remote.concealed)
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

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        hub.readItem(token, item: item, of: peer, completion)
    }

    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void) {
        hub.pullItem(order, from: peer, completion)
    }

    func cancelPull(_ id: ItemPullID) { hub.cancelPull(id, on: peer) }

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding
    ) throws(WireError) -> ItemPullOrder {
        try sink.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing)
    }
}
