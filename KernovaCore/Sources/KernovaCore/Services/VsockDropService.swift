import Foundation
import KernovaKit
import KernovaLogging

/// Takes the guest's own drags over at the display's edge so they carry on onto
/// the Mac. Files dropped on the display reach the guest through the agent hub
/// instead (`HubDropService`).
///
/// One instance serves one accepted channel on `KernovaVsockPort.drop`. The
/// guest offers each drag on it as metadata (``guestDrag``), a
/// ``GuestDragTake`` hands it over, and each item is pulled into this
/// connection's staging as a Mac destination asks for it, on a vsock data
/// connection of its own — the transfer engine a paste runs on.
@MainActor
@Observable
package final class VsockDropService: VsockFeatureService, VsockDataConnectionAccepting {
    // MARK: - Observable state

    /// `true` between `start()` and the settle — `stop()`, or the channel
    /// ending under it.
    package var isConnected: Bool { phase == .connected }

    /// The drag the guest is offering that nothing has taken yet, or `nil`.
    ///
    /// Cleared when the guest withdraws it, when it is taken, when a new press
    /// begins on the display, and with the channel. The new-press clearing is a
    /// cheap filter only: the guest's own check that a take names its current
    /// press is the authority.
    package private(set) var guestDrag: ClipboardInboundDrag?

    // MARK: - Private state

    private let label: String

    /// This connection: the guest's drags, and the transfers pulling them.
    ///
    /// `nonisolated` so an accepted data connection can be forwarded from the
    /// listener's queue.
    nonisolated private let endpoint: ClipboardEndpoint

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    nonisolated private var connectionTag: ClipboardConnectionTag { endpoint.connectionTag }

    /// This VM's transfer report, which every surface renders. Shared with the
    /// VM's clipboard service, so one readout covers both.
    private let reporter: ClipboardTransferReporter

    /// Where the guest's dragged items land before each is moved to where it was
    /// dropped. Each drag's folder is discarded when its take finishes, and by
    /// nothing else: concurrent takes and a landing still running past the
    /// channel's end each read their own.
    private let dragStaging: ClipboardFileStaging

    /// Every take still running on this connection, by drag generation.
    @ObservationIgnored private var takes: [UInt64: GuestDragTake] = [:]

    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    private let dragNamingDeadline: TimeInterval
    private let clock: any EngineClock

    // `nonisolated` so a log line can be written from any thread; `Logger` is
    // Sendable.
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VsockDropService")

    // MARK: - Settle contract

    /// Notified once when the channel dies on its own, never on an
    /// owner-requested `stop()`.
    @ObservationIgnored var onChannelLost: (@MainActor () -> Void)?

    /// Where this service is in its one connection.
    private enum Phase {
        case idle
        case connected
        /// Settled, whichever of the owner and the channel's own end got here
        /// first; nothing leaves it, so a reconnect is served by a fresh
        /// instance.
        case settled
    }

    private var phase = Phase.idle

    #if DEBUG
    var lifecycleTasksForTesting: [Task<Void, Never>] { endpoint.lifecycleTasksForTesting }
    var dragStagingForTesting: ClipboardFileStaging { dragStaging }

    /// Test seam: ends the endpoint's session as the channel's own end does
    /// before its hop to the main actor, leaving every take unaware.
    func endEndpointSessionForTesting() { endpoint.stop() }

    /// Test seam: offers the files at `urls` to the guest — a host→guest frame
    /// a test can order the frames sent before it behind.
    func offerForTesting(_ urls: [URL]) {
        let intake = ClipboardPasteboardReader.resolve(filesAt: urls, sizeOf: { _ in 0 })
        _ = endpoint.offer(ClipboardContent(representations: intake.representations), skippedBeforeOffer: 0)
    }
    #endif

    // MARK: - Init

    init(
        channel: VsockChannel, label: String, reporter: ClipboardTransferReporter,
        stagingRoot: ProcessStagingRoot, stagingKey: String,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        dragNamingDeadline: TimeInterval = GuestDragTake.namingDeadline,
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        self.label = label
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.dragNamingDeadline = dragNamingDeadline
        self.clock = clock
        let staging = ClipboardFileStaging(
            label: "host-drag-\(stagingKey)", root: stagingRoot, receivingOn: .drop, as: .host,
            freeSpaceProvider: freeSpaceProvider)
        self.dragStaging = staging
        self.endpoint = ClipboardEndpoint(
            channel: channel,
            configuration: ClipboardEndpoint.Configuration(
                role: .host, kind: .drop, label: label, peerName: label,
                // A dragged item is written where the user drops it, never on a
                // pasteboard, so no OS paste deadline bounds it.
                maxPasteBytes: { .max }, staging: staging,
                progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap,
                clock: clock),
            reporter: reporter)
        endpoint.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle else { return }
        phase = .connected
        endpoint.start()
        Self.logger.log(
            .notice,
            "Vsock drop service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Takes over one item's data connection, accepted on the drop data port,
    /// from whatever thread the listener hands it over on.
    ///
    /// Takes ownership of `fd` on every path.
    nonisolated func acceptDataConnection(fd: Int32) {
        endpoint.acceptDataConnection(fd: fd)
    }

    /// Tears the service down at the owner's request.
    ///
    /// The owner is not called back — it already knows.
    func stop() {
        settle(reason: .ownerRequested)
    }

    /// Tears the service down once its channel is over, whether the owner asked
    /// or the channel simply ended.
    ///
    /// Idempotent and terminal: the consume loop's own settle and an owner's
    /// `stop()` race by construction, and only the first one through finds the
    /// service unsettled. A service settled before it ever connected skips the
    /// notification and the log line.
    private func settle(reason: VsockSettleReason) {
        guard phase != .settled else { return }
        let wasConnected = phase == .connected
        phase = .settled
        endpoint.stop()
        guestDrag = nil
        for take in Array(takes.values) { take.channelEnded() }
        takes.removeAll()
        guard wasConnected else { return }
        Self.logger.log(
            .notice,
            "Vsock drop service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
        // Last, so the owner observes fully-settled state from inside the
        // callback.
        if case .channelLost = reason {
            onChannelLost?()
        }
    }

    // MARK: - Dragging out

    /// Records that a press began on the display, which no drag offered before
    /// it belongs to.
    func displayPressBegan() {
        guestDrag = nil
    }

    /// Takes over the guest's drag `generation` for `display`, once the pointer
    /// left the display holding it — or `nil` when that is not the drag the
    /// guest is offering now.
    ///
    /// The take runs while `holds` stays true; the condition turning false
    /// abandons it. Any earlier take is superseded: one still handing off is
    /// abandoned, and one a Mac session carries keeps writing what its
    /// destination asks for.
    func takeGuestDrag(
        generation: UInt64, display: any GuestDragDisplay,
        while holds: @escaping @MainActor () -> Bool
    ) -> GuestDragTake? {
        guard isConnected, let drag = guestDrag, drag.generation == generation else { return nil }
        guestDrag = nil
        for earlier in Array(takes.values) { earlier.supersede() }
        let take = GuestDragTake(
            drag: drag, endpoint: endpoint, display: display, reporter: reporter, peerName: label,
            progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap,
            namingDeadline: dragNamingDeadline, clock: clock, holds: holds,
            onFinished: { [weak self, dragStaging] take in
                self?.takes[take.generation] = nil
                dragStaging.discardGeneration(take.generation)
            })
        takes[generation] = take
        take.begin()
        return take
    }
}

// MARK: - Endpoint delegate

extension VsockDropService: ClipboardEndpointDelegate {
    /// Settles here rather than waiting for whatever replaces this service.
    ///
    /// `isConnected` is what the display reads to decide whether it may take a
    /// drop, and the guest closes this channel on every control reconnect (its
    /// client pauses until the next `Hello`), so a service left standing would
    /// keep advertising a drop it can no longer send.
    package func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        settle(reason: .channelLost)
    }

    package func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDrag drag: ClipboardInboundDrag) {
        guestDrag = drag
    }

    package func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason
    ) {
        guard reason == .released, let generation else { return }
        if guestDrag?.generation == generation { guestDrag = nil }
        takes[generation]?.guestWithdrew()
    }

    package func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveDragHandOff step: ClipboardDragHandOffStep,
        generation: UInt64
    ) {
        guard let take = takes[generation] else {
            Self.logger.log(
                .debug,
                "Hand-off step for gen=\(generation, privacy: .public) with no take running (conn=\(self.connectionTag, privacy: .public)) — ignored"
            )
            return
        }
        take.handOff(step)
    }
}
