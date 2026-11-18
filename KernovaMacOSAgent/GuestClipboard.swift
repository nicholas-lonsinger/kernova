import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization
import KernovaWire

/// The guest's clipboard over the session peer's CLIPBOARD items: its ``ClipboardEnd`` fed the host's policy, the
/// session's hold on the console and the connection, and what the end does shown as ``activity``.
@MainActor
final class GuestClipboard {
    /// The logger a clipboard logs through unless it is built with another.
    nonisolated static let defaultLogger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestClipboard")

    private let logger: KernovaLogger

    /// The guest's whole clipboard mechanism.
    let end: ClipboardEnd<ClipboardGuest>

    private let onNotice: @Sendable () -> Void
    /// The paste ceiling the host's policy sets: what the end's publishes and pulls read, from any thread.
    private let pasteCeiling: Locked<Int>

    /// The latest clipboard activity, for the menu-bar status line.
    private(set) var activity: ClipboardActivity = .disabled

    /// A clipboard over `pasteboard`, landing the host's representations and calling in copied promises under
    /// `stagingRoot`, logging through `logger`, and raising `onNotice` when a refusal lands in ``activity``. A paste
    /// lands no more than `pasteCeiling` bytes, and a copy is offered only at the host's request, until the host's
    /// policy says otherwise.
    init(
        pasteboard: any ClipboardPasteboard, stagingRoot: ProcessStagingRoot,
        pasteCeiling: Int = ClipboardPasteLimit.defaultBytes, logger: KernovaLogger = GuestClipboard.defaultLogger,
        onNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.logger = logger
        self.onNotice = onNotice
        let ceiling = Locked(pasteCeiling)
        self.pasteCeiling = ceiling
        // Its own provider registry: the providers it holds are the guest pasteboard's alone.
        end = ClipboardEnd(
            pasteboard: pasteboard, gate: .onCommand, stagingLabel: "agent", stagingRoot: stagingRoot,
            pasteCeiling: { ceiling.withLock { $0 } }, providerRegistry: LazyClipboardProviderRegistry(),
            logger: logger)
        end.onEvent = { [weak self] in self?.heard($0) }
    }

    /// The general pasteboard's clipboard.
    convenience init(stagingRoot: ProcessStagingRoot, onNotice: @escaping @Sendable () -> Void) {
        self.init(pasteboard: NSPasteboard.general, stagingRoot: stagingRoot, onNotice: onNotice)
    }

    /// CLIPBOARD's owner on the session peer's connection, calling into it through `calls`.
    nonisolated func owner(calls: PeerItemCalls) -> ItemFeatureOwner<Void> {
        let end = end
        let link = AgentClipboardLink(calls: calls)
        return ItemFeatureOwner(
            usable: { [weak self] usable in
                MainActorBridge.async { self?.setLink(usable == nil ? nil : link) }
            },
            events: { _, event in
                if case .pullEnded(_, let id, let result) = event { return end.pullEnded(id, result) }
                MainActorBridge.async { end.handle(event, on: link) }
            },
            content: { id, request, _ in end.content(id, request) },
            policy: { [weak self] policy in MainActorBridge.async { self?.apply(policy) } })
    }

    /// Takes the paste ceiling the host's policy sets, the default when it sets none, and offers at every copy
    /// while it runs passthrough, otherwise only at the host's request.
    func apply(_ policy: PolicySnapshot) {
        let value = ClipboardPolicyValue(policy)
        let ceiling = ClipboardPasteLimit.fromPolicy(value?.maxPasteBytes ?? 0)
        let changed = pasteCeiling.withLock { held in
            defer { held = ceiling }
            return held != ceiling
        }
        end.setGate(value?.passthrough == true ? .everyCopy : .onCommand)
        guard changed else { return }
        logger.log(.notice, "The host sets the paste ceiling to \(ceiling, privacy: .public) bytes")
        end.pasteCeilingChanged()
    }

    /// Whether this session owns the console now: only then does this side offer.
    func setOnConsole(_ onConsole: Bool) {
        end.setMayOffer(onConsole)
    }

    /// The connection that can use CLIPBOARD now, or none.
    func setLink(_ link: (any ClipboardItemLink)?) {
        end.setLink(link)
        if link == nil {
            activity = .disabled
        } else if case .disabled = activity {
            activity = .enabled
        }
    }

    /// Ends the clipboard's connection: nothing more crosses.
    func stop() {
        setLink(nil)
    }

    // MARK: What the end did

    private func heard(_ event: ClipboardEndEvent) {
        switch event {
        case .readEnded(_, .offered(skipped: 0)):
            activity = .offeredToHost
        case .readEnded(_, .offered(let skipped)):
            notice(.copyPartlyCarried(skipped: skipped))
        case .readEnded(_, .unreadable), .readEnded(_, .nothingCarriable):
            notice(.copyCarriedNothing)
        case .published(.written):
            activity = .offeredFromHost
        case .published(.writtenWithoutFiles(_, let limitBytes)), .published(.tooLarge(let limitBytes)):
            notice(.pasteRefused(.pasteTooLarge, pasteLimitBytes: limitBytes))
        case .published(.writeFailed), .pasteRefused:
            notice(.pasteRefused(.pasteFailed, pasteLimitBytes: nil))
        case .pullFailed(let error) where error.code == .tooLarge:
            let ceiling = pasteCeiling.withLock { $0 }
            logger.log(
                .notice, "A paste of the host's clipboard is over the \(ceiling, privacy: .public)-byte paste ceiling")
            notice(.pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling))
        case .served:
            activity = .sentToHost
        case .landed:
            activity = .receivedFromHost
        case .retracted(let retraction, let ending):
            guard let line = ClipboardRetractionLog.line(retraction, on: .guest, because: ending) else { return }
            logger.log(.notice, "\(line, privacy: .public)")
        case .readBegan, .readEnded(_, .nothingToCopy), .readEnded(_, .heldByFarSide), .readEnded(_, .superseded),
            .notAdmitted, .published(.nothingToWrite), .requestRefused, .pullFailed:
            break
        }
    }

    /// Shows `activity`, a refusal or a copy's loss, in a callout of its own.
    private func notice(_ activity: ClipboardActivity) {
        self.activity = activity
        onNotice()
    }
}

/// CLIPBOARD's calls through the session peer's connection.
struct AgentClipboardLink: ClipboardItemLink {
    let calls: PeerItemCalls

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        calls.offerItems(offer, feature: .clipboard, completion)
    }

    func withdrawOffer(_ token: Data, code: ErrorCode) { calls.withdrawOffer(token, code: code) }
    func releaseOffer(_ token: Data) { calls.releaseOffer(token) }
    func refuseOffer(_ token: Data, _ error: WireError) { calls.refuseOffer(token, error) }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        calls.readItem(token, item: item, completion)
    }

    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void) {
        calls.pullItem(order, completion)
    }

    func cancelPull(_ id: ItemPullID) { calls.cancelPull(id) }

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder {
        try calls.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
    }
}
