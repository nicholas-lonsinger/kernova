import Foundation
import KernovaLogging
import KernovaSynchronization

/// What the peer has offered this side, and every pull that materializes it.
///
/// An offer arrives as metadata alone; its bytes cross only when something
/// consumes them — docs/CLIPBOARD.md, "Pay on consume". So this owns the
/// promise table and its per-representation cache, the one pull core every
/// gesture runs, the gate deciding what a paste may ask for, and what a refusal
/// reports — for either end of either channel. The owners differ only in what
/// they do with a representation once it lands.
@MainActor
public final class ClipboardInboundOffers {
    // MARK: - Values the owner reads

    /// One offer the peer has made, as its owner reads it back.
    public struct InboundOffer: Sendable {
        /// The generation the peer announced it under; a transfer id's high bits.
        public let generation: UInt64
        /// Every representation the offer declared, at its wire index.
        public let reps: [Kernova_V1_ClipboardRepresentationInfo]
        /// Whether the offer carried `org.nspasteboard.ConcealedType`.
        public let isConcealed: Bool
        /// Indices into ``reps`` of what this side keeps
        /// (``ClipboardPromisePolicy/keeps(_:)``) — what a surface may show and a
        /// pull may ask for.
        public let keptIndices: [Int]
    }

    /// Why an offer this side was holding is no longer live.
    public enum RetractReason: Equatable, Sendable {
        /// A newer offer replaced it. `hasSuccessor` is false when that offer
        /// left nothing this side keeps, so nothing took its place.
        case superseded(hasSuccessor: Bool)
        /// The peer withdrew it.
        case released
    }

    /// How long a reported paste refusal silences further refusals of the same
    /// offer.
    ///
    /// One paste gesture fires one data provider per promised item, so its
    /// refusals arrive as a burst and are worth one message; a paste made after
    /// the window is a second gesture and is owed its own answer.
    public static let refusalBurstWindow: TimeInterval = 2

    // MARK: - Stored state

    /// One offer the peer has made and this side can still pull from.
    private final class Entry {
        let generation: UInt64
        /// Every representation declared, at its wire index; a drag's folders
        /// and promised items take their sizes when the peer's `DragSizes`
        /// arrives, and its promised items their names from `DragNames`.
        var reps: [Kernova_V1_ClipboardRepresentationInfo]
        let isConcealed: Bool
        /// A drag's promised items, by index.
        var promised: Set<Int> = []
        /// Representations already pulled, each at most once and then served to
        /// every flavor and every later fire that asks.
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// Temp-file URLs for inline payloads staged on demand, so a repeated
        /// `.fileURL` fire returns the same file instead of minting
        /// `name 2.ext`.
        var stagedInlineURLs: [Int: URL] = [:]
        /// Monotonic count of cache writes, so an owner hashing off its actor can
        /// tell one landed while it worked.
        var epoch = 0
        /// The waiter each async join currently holds, so a Cancel on the readout
        /// that started them can leave those pulls — and only those — rather than
        /// tearing down a transfer a paste fire is also waiting on.
        var joinedWaiters: [Int: LazyPullCoordinator.Waiter] = [:]
        /// When this offer's last refusal was reported, opening the burst window
        /// that keeps the rest of one paste's provider fires quiet.
        var lastRefusalReportedAt: EngineInstant?

        init(
            generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
        ) {
            self.generation = generation
            self.reps = reps
            self.isConcealed = isConcealed
        }
    }

    nonisolated private let session: ClipboardControlSession
    nonisolated private let reporter: ClipboardTransferReporter
    nonisolated private let staging: ClipboardFileStaging
    nonisolated private let peerName: String
    nonisolated private let lazyPullTimeout: TimeInterval
    nonisolated private let progressRevealDelay: TimeInterval
    nonisolated private let progressIdleGap: TimeInterval

    /// Bridges every pull to the off-actor receive: the first caller for a
    /// transfer id opens it and the rest join, so a preview fetch and a paste
    /// fire for one representation share a single transfer.
    nonisolated private let coordinator = LazyPullCoordinator()

    /// Transfer ids of the synchronous pulls parked on this connection, so a
    /// cancel can stop the peer producing bytes for them.
    ///
    /// Held off the main actor: a blocking fire clears its id from whichever
    /// thread it holds, and the main hop that would cost is the one a paste
    /// must not pay.
    nonisolated private let syncPulls = Locked<Set<UInt64>>([])

    /// Takes every parked pull's id belonging to `generation` out, returning
    /// them for the caller to tear down.
    private func takeSyncPulls(generation: UInt64) -> [UInt64] {
        syncPulls.withLock { ids in
            let matched = ids.filter { ClipboardTransferID.generation(of: $0) == generation }
            ids.subtract(matched)
            return Array(matched)
        }
    }

    /// The items of one drag whose offer carried no size — its folders and
    /// promised items — that the peer has not settled yet.
    private struct DragReadiness: Sendable {
        /// Each item still waiting for its size, with the latch its pulls wait
        /// on.
        var pending: [Int: OneShotLatch]
        /// Items the peer said will never be sized, whose pulls are refused.
        var unavailable: Set<Int> = []
    }

    /// Each drag with an item not yet ready to pull, by generation — held off
    /// the main actor, so the session's end can wake the pulls waiting on it
    /// without a hop.
    ///
    /// An entry leaves once every item it held has been sized, or its drag is
    /// retired. The session's end opens every latch and leaves the entries, so
    /// a pull that wakes is refused rather than run at a size nobody measured.
    nonisolated private let dragReadiness = Locked<[UInt64: DragReadiness]>([:])

    /// The naming of each drag's promised items, which the session's reader
    /// thread feeds (``observeOffMain(_:)``).
    nonisolated let dragNaming = ClipboardDragNaming()

    private let clock: any EngineClock
    private let maxPasteBytes: @MainActor () -> Int

    /// Called with each clipboard offer or drop the peer makes, once it is live
    /// here.
    ///
    /// Set after construction rather than taken at init: an owner that holds this
    /// as a stored property has no `self` to hand over while building it.
    public var onOfferReceived: @MainActor (InboundOffer) -> Void = { _ in }

    /// Called with each drag the peer offers, once it is live here, its items
    /// already made safe (``ClipboardDraggedItem``).
    public var onDragReceived: @MainActor (ClipboardInboundDrag) -> Void = { _ in }

    /// Called when an offer this side was holding stops being servable, with the
    /// generation retired — `nil` when there was none, which is still the moment
    /// to withdraw whatever this side published for the peer's last offer.
    public var onOfferRetracted: @MainActor (UInt64?, RetractReason) -> Void = { _, _ in }

    /// Called with what an inbound gesture just did, for a surface to render.
    public var onActivity: @MainActor (ClipboardEndpoint.Activity) -> Void = { _ in }

    /// Called with every refusal this side raises for the peer's offer — a
    /// pre-flight check, a gate, or a transfer that failed under an operation
    /// this object owns.
    ///
    /// The owner decides where a refusal belongs: the host renders it on the VM's
    /// transfer report, while the guest's own menu line (``onActivity``) is the
    /// account it owes, and a failed report there would displace another agent's
    /// running transfer.
    public var onRefusal: @MainActor (ClipboardTransferGesture, ClipboardTransferFailure) -> Void =
        { _, _ in }

    private var entries: [UInt64: Entry] = [:]

    /// The clipboard offer the peer currently holds here; `0` when it holds none.
    /// A drop or a drag keeps several entries at once and never sets it.
    private var currentGeneration: UInt64 = 0

    #if DEBUG
    /// Test seam: awaited between a join's pull resolving and the supersession
    /// re-check that decides whether to cache it, so a test can drive a newer
    /// offer or a teardown into that exact gap.
    var afterInboundPullForTesting: (@MainActor () async -> Void)?

    /// Test seam: called each time a pull starts waiting for a drag item's
    /// size, on the pulling thread.
    nonisolated let sizeWaitBeganForTesting = Locked<(@Sendable () -> Void)?>(nil)

    /// Test seam: how many pulls ``resolve(generation:repIndex:servesFileURL:expectedUTI:)``
    /// has handed a plan to, on the main actor every pull passes through before
    /// it can dial.
    private(set) var pullsStartedForTesting = 0
    #endif

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardInboundOffers")

    /// Creates the inbound half of one connection.
    ///
    /// `maxPasteBytes` is read at each gate check rather than captured, so a
    /// ceiling the user or the host changes reaches a live session.
    public init(
        session: ClipboardControlSession,
        reporter: ClipboardTransferReporter,
        staging: ClipboardFileStaging,
        peerName: String,
        maxPasteBytes: @escaping @MainActor () -> Int,
        lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        self.session = session
        self.reporter = reporter
        self.staging = staging
        self.peerName = peerName
        self.maxPasteBytes = maxPasteBytes
        self.lazyPullTimeout = lazyPullTimeout
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.clock = clock
    }

    // MARK: - Role and kind

    nonisolated private var tag: ClipboardConnectionTag { session.connectionTag }

    /// How the peer's offers behave on this side.
    nonisolated private var discipline: ClipboardOfferDiscipline { session.inboundDiscipline }

    /// Whether an inbound-paste refusal also goes to the peer as an `Error`
    /// frame.
    ///
    /// The guest's refusal is the only account the host's clipboard window can
    /// render of a paste made inside the VM; the host renders the peer's frame
    /// itself and has nothing to send back.
    nonisolated private var sendsPasteRefusalsToPeer: Bool { session.role == .guest }

    // MARK: - Reading what is offered

    /// The clipboard offer the peer currently holds here, or `nil`.
    public var inboundOffer: InboundOffer? { entries[currentGeneration].map(Self.offer(for:)) }

    /// Whether `generation` still names an offer this side may pull from.
    ///
    /// `nonisolated` for a caller reading it the moment its pull wakes: a cancel
    /// retires the offer *before* waking the pulls it aborts, so this is how a
    /// blocking caller tells a cancellation from a transfer that failed.
    nonisolated public func hasLiveOffer(generation: UInt64) -> Bool {
        MainActorBridge.sync { self.entries[generation] != nil }
    }

    /// The representation already pulled for `(generation, repIndex)`, or `nil`.
    public func materialized(
        generation: UInt64, repIndex: Int
    ) -> ClipboardContent.Representation? {
        entries[generation]?.materialized[repIndex]
    }

    /// How many representations of `generation` have been cached, so an owner
    /// hashing off its actor can tell one landed while it worked.
    public func materializationEpoch(generation: UInt64) -> Int {
        entries[generation]?.epoch ?? 0
    }

    /// The offer's paste-bound total against the ceiling in force, or `nil` when
    /// `generation` names no live offer.
    public func pasteBudget(generation: UInt64) -> ClipboardPromisePolicy.PasteBudget? {
        guard let entry = entries[generation] else { return nil }
        return ClipboardPromisePolicy.pasteBudget(entry.reps, limit: maxPasteBytes())
    }

    /// The sum of every size `generation` declares as this side knows it now —
    /// a drag's folders and promised items count only once their sizes have
    /// arrived — or `0` when it names no live offer.
    public func byteCount(generation: UInt64) -> UInt64 {
        entries[generation]?.reps.reduce(UInt64(0)) { $0.saturatingAdding($1.byteCount) } ?? 0
    }

    /// The pasteboard items to promise for `generation`, or `nil` when it names
    /// no live offer.
    public func promisePlan(generation: UInt64) -> ClipboardPasteboardItemPlan? {
        guard let entry = entries[generation] else { return nil }
        return ClipboardPasteboardItemPlan.plan(
            for: ClipboardPromisePolicy.descriptors(for: entry.reps))
    }

    private static func offer(for entry: Entry) -> InboundOffer {
        InboundOffer(
            generation: entry.generation, reps: entry.reps, isConcealed: entry.isConcealed,
            keptIndices: entry.reps.indices.filter { ClipboardPromisePolicy.keeps(entry.reps[$0]) })
    }

    // MARK: - Taking an offer

    /// Takes on the peer's clipboard offer, retiring whatever it supersedes.
    ///
    /// The retraction is raised for every offer, not only one that replaces a
    /// live entry: what this side left standing for the peer — a pasteboard
    /// write outliving the session that published it — is retired by the offer
    /// that makes it unservable, and only its owner can tell whether one is
    /// there.
    public func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        let reps = boundedReps(offer.repInfo, generation: offer.generation)
        let kept = reps.indices.filter { ClipboardPromisePolicy.keeps(reps[$0]) }
        guard !kept.isEmpty else {
            if !reps.isEmpty {
                Self.logger.log(
                    .warning,
                    "Dropped the clipboard offer from '\(self.peerName, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.tag, privacy: .public)): none of its \(reps.count, privacy: .public) representation(s) survived receive-side filtering"
                )
            }
            retireCurrentOffer(reason: .superseded(hasSuccessor: false))
            return
        }
        // Ahead of the retraction, whose own report explains this very offer and
        // must be what stands.
        reporter.clearFinished()
        retireCurrentOffer(reason: .superseded(hasSuccessor: true))
        let entry = Entry(
            generation: offer.generation, reps: reps, isConcealed: offer.isConcealed)
        entries[offer.generation] = entry
        currentGeneration = offer.generation
        onOfferReceived(Self.offer(for: entry))
        Self.logger.log(
            .notice,
            "Received a clipboard offer from '\(self.peerName, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.tag, privacy: .public), \(reps.count, privacy: .public) reps) — metadata only"
        )
    }

    /// Retires the offer the peer has withdrawn.
    public func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        guard entries[release.generation] != nil, currentGeneration == release.generation else {
            return
        }
        retireCurrentOffer(reason: .released)
        Self.logger.log(
            .debug,
            "'\(self.peerName, privacy: .public)' released its clipboard offer (gen=\(release.generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// Takes on one drop the peer has offered.
    ///
    /// Drops are independent jobs, never a supersession chain: a second drop
    /// arriving while the first still streams leaves both live, because the user
    /// asked for both sets of files.
    public func handleDropOffer(_ offer: Kernova_V1_DropOffer) {
        guard entries[offer.generation] == nil else {
            Self.logger.log(
                .warning,
                "Duplicate drop offer for gen=\(offer.generation, privacy: .public) (conn=\(self.tag, privacy: .public)) — ignored"
            )
            return
        }
        let reps = boundedReps(offer.repInfo, generation: offer.generation)
        guard !reps.isEmpty else {
            session.sendDropComplete(
                generation: offer.generation, outcome: .failed, code: .dropFailed,
                message: "The drop carried no files")
            return
        }
        let entry = Entry(generation: offer.generation, reps: reps, isConcealed: false)
        entries[offer.generation] = entry
        onOfferReceived(Self.offer(for: entry))
        Self.logger.log(
            .notice,
            "Accepted a drop of \(reps.count, privacy: .public) item(s) from '\(self.peerName, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// Takes on one drag the peer has offered.
    ///
    /// Independent like a drop: a drag the owner has taken stays pullable while
    /// the peer offers the next. Each item's name and declared flags are made
    /// safe here, at intake, so nothing downstream reads a peer-supplied path
    /// component or an inline flag that would skip the free-space pre-flight;
    /// the declared UTI is kept as sent, since a pull must echo it, and the
    /// owner reads the usable type from ``ClipboardDraggedItem``. A folder's
    /// or a promised item's size is `0` until the peer's `DragSizes`
    /// (``handleDragSizes(_:)``) settles it, and no pull of it starts before
    /// then; a promised item has no name until `DragNames`
    /// (``handleDragNames(_:)``).
    public func handleDragOffer(_ offer: Kernova_V1_DragOffer) {
        guard entries[offer.generation] == nil else {
            Self.logger.log(
                .warning,
                "Duplicate drag offer for gen=\(offer.generation, privacy: .public) (conn=\(self.tag, privacy: .public)) — ignored"
            )
            return
        }
        let promised = Set(Self.promisedItems(of: offer).keys)
        let reps = boundedReps(offer.repInfo, generation: offer.generation).enumerated().map {
            index, info -> Kernova_V1_ClipboardRepresentationInfo in
            var safe = info
            // `is_inline` is meaningless for a drag, whose every item lands as a
            // file — and an inline rep would skip the on-disk pre-flight.
            safe.isInline = false
            if promised.contains(index) {
                safe.filename = ""
                safe.byteCount = 0
                return safe
            }
            safe.filename = ClipboardDraggedItem.safeFilename(
                info.filename, isDirectory: info.isDirectory)
            if info.isDirectory { safe.byteCount = 0 }
            return safe
        }
        guard !reps.isEmpty else {
            // Nothing to take: the host is done with it before it began.
            dragNaming.retire(generation: offer.generation)
            session.sendDragComplete(generation: offer.generation)
            return
        }
        let entry = Entry(generation: offer.generation, reps: reps, isConcealed: false)
        entry.promised = promised
        entries[offer.generation] = entry
        let unsized = promised.union(reps.indices.filter { reps[$0].isDirectory })
        if !unsized.isEmpty {
            dragReadiness.withLock {
                $0[offer.generation] = DragReadiness(
                    pending: Dictionary(uniqueKeysWithValues: unsized.map { ($0, OneShotLatch()) }))
            }
        }
        onDragReceived(
            ClipboardInboundDrag(
                generation: offer.generation,
                items: reps.indices.map {
                    ClipboardDraggedItem(
                        repIndex: $0, declared: reps[$0], isPromised: promised.contains($0))
                }))
        Self.logger.log(
            .notice,
            "Received a drag of \(reps.count, privacy: .public) item(s), \(promised.count, privacy: .public) promised, from '\(self.peerName, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.tag, privacy: .public)) — metadata only"
        )
    }

    /// The promised items `offer` declares, each with whether it is a
    /// directory: every index it names that survives the intake bounds
    /// (``ClipboardOfferBounds``).
    nonisolated static func promisedItems(of offer: Kernova_V1_DragOffer) -> [Int: Bool] {
        let count = min(offer.repInfo.count, ClipboardContent.maxOfferableRepresentations)
        var promised: [Int: Bool] = [:]
        for key in offer.promised where Int(key) < count {
            promised[Int(key)] = offer.repInfo[Int(key)].isDirectory
        }
        return promised
    }

    /// Settles the items of a drag that a `DragSizes` lists — each sized one
    /// takes its size, each unavailable one is refused from then on — and
    /// wakes the pulls waiting on them.
    ///
    /// A size is clamped like any declared one. An item the frame leaves out
    /// keeps waiting for a later frame, the drag's retirement, or the
    /// session's end.
    public func handleDragSizes(_ sizes: Kernova_V1_DragSizes) {
        let generation = sizes.generation
        guard let entry = entries[generation] else {
            Self.logger.log(
                .debug,
                "Item sizes for gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)', which is not live (conn=\(self.tag, privacy: .public)) — ignored"
            )
            return
        }
        let settled = dragReadiness.withLock { table -> DragSettlement in
            guard var readiness = table[generation] else { return DragSettlement() }
            var settlement = DragSettlement()
            for key in sizes.byteCounts.keys.sorted() {
                guard let latch = readiness.pending.removeValue(forKey: Int(key)) else { continue }
                settlement.sized.append(Int(key))
                settlement.latches.append(latch)
            }
            for key in sizes.unavailable {
                guard let latch = readiness.pending.removeValue(forKey: Int(key)) else { continue }
                readiness.unavailable.insert(Int(key))
                settlement.unavailable.append(Int(key))
                settlement.latches.append(latch)
            }
            settlement.waiting = readiness.pending.count
            table[generation] =
                readiness.pending.isEmpty && readiness.unavailable.isEmpty ? nil : readiness
            return settlement
        }
        // Ahead of the wake, so a pull it releases is planned against them.
        for index in settled.sized {
            entry.reps[index].byteCount = min(
                sizes.byteCounts[UInt32(index)] ?? 0, ClipboardOfferBounds.maxDeclaredByteCount)
            if entry.promised.contains(index), entry.reps[index].filename.isEmpty {
                // Sized but never named: it still lands under a name of its own.
                entry.reps[index].filename = ClipboardDraggedItem.safeFilename(
                    "", isDirectory: entry.reps[index].isDirectory)
            }
        }
        for latch in settled.latches { latch.open() }
        Self.logger.log(
            settled.unavailable.isEmpty ? .notice : .warning,
            "Received sizes for \(settled.sized.count, privacy: .public) item(s) of the drag from '\(self.peerName, privacy: .public)', \(settled.unavailable.count, privacy: .public) unavailable and \(settled.waiting, privacy: .public) still waiting (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// What one `DragSizes` settled.
    private struct DragSettlement {
        var sized: [Int] = []
        var unavailable: [Int] = []
        /// The latches of every item settled, to open once the sizes are in.
        var latches: [OneShotLatch] = []
        /// How many of the drag's items still wait.
        var waiting = 0
    }

    /// Gives the promised items a `DragNames` lists the names the peer
    /// reports they took, so a pull stages each under its own. An item keeps
    /// the first name it is given, and an empty name names nothing.
    public func handleDragNames(_ names: Kernova_V1_DragNames) {
        guard let entry = entries[names.generation] else { return }
        var named = 0
        for (key, name) in names.filenames where !name.isEmpty {
            let index = Int(key)
            guard entry.promised.contains(index), entry.reps[index].filename.isEmpty else { continue }
            entry.reps[index].filename = ClipboardDraggedItem.safeFilename(
                name, isDirectory: entry.reps[index].isDirectory)
            named += 1
        }
        Self.logger.log(
            .debug,
            "'\(self.peerName, privacy: .public)' named \(named, privacy: .public) of the \(names.filenames.count, privacy: .public) promised item(s) a DragNames lists (gen=\(names.generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// Wakes every pull waiting on `generation`'s items, which it no longer
    /// has, and fails a naming still waiting on it: the drag is retired.
    private func releaseDrag(generation: UInt64) {
        let readiness = dragReadiness.withLock { $0.removeValue(forKey: generation) }
        for latch in readiness.map({ Array($0.pending.values) }) ?? [] { latch.open() }
        dragNaming.retire(generation: generation)
    }

    // MARK: - Naming promised items

    /// Records what a drag frame the peer sent says about naming its promised
    /// items, on the session's reader thread, before the frame is queued to the
    /// main actor — where a resolve may be holding the thread that would run
    /// it.
    ///
    /// For the host's drop channel only. The frame's main-actor dispatch still
    /// runs, and is where one arriving the wrong way closes the channel.
    nonisolated func observeOffMain(_ frame: Frame) {
        switch frame.payload {
        case .dragOffer(let offer):
            dragNaming.track(generation: offer.generation, promised: Self.promisedItems(of: offer))
        case .dragHandOff(let handOff):
            switch ClipboardDragHandOffStep(handOff) {
            case .resolving:
                dragNaming.acknowledged(generation: handOff.generation)
            case .resolveRefused:
                dragNaming.failed(generation: handOff.generation, .resolveRefused)
            case .failed(let code, _):
                dragNaming.failed(generation: handOff.generation, .handOffFailed(code))
            case .armed, .targeted, .caught:
                break
            }
        case .dragNames(let names):
            dragNaming.named(generation: names.generation, filenames: names.filenames)
        case .dragRelease(let release):
            dragNaming.failed(generation: release.generation, .dragNotLive)
        default:
            break
        }
    }

    /// Starts naming `generation`'s promised items — see
    /// ``ClipboardDragNaming/begin(generation:deadline:send:releasingGuestButton:)``.
    nonisolated func beginDragNaming(
        generation: UInt64, deadline: DispatchTime, releasingGuestButton: () -> Void
    ) -> ClipboardDragNamingFailure? {
        dragNaming.begin(
            generation: generation, deadline: deadline, send: { sendDragResolve(generation) },
            releasingGuestButton: releasingGuestButton)
    }

    /// Names promised item `repIndex` of `generation` — see
    /// ``ClipboardDragNaming/resolveName(generation:repIndex:deadline:send:releasingGuestButton:)``.
    nonisolated func resolveDragName(
        generation: UInt64, repIndex: Int, deadline: DispatchTime,
        releasingGuestButton: () -> Void
    ) -> Result<String, ClipboardDragNamingFailure> {
        dragNaming.resolveName(
            generation: generation, repIndex: repIndex, deadline: deadline,
            send: { sendDragResolve(generation) }, releasingGuestButton: releasingGuestButton)
    }

    /// Asks the peer to have `generation`'s promised items called in,
    /// reporting whether the ask went out.
    nonisolated private func sendDragResolve(_ generation: UInt64) -> Bool {
        do {
            try session.sendDragResolve(generation: generation)
        } catch {
            Self.logger.log(
                .warning,
                "Failed to ask '\(self.peerName, privacy: .public)' to name the promised items of gen=\(generation, privacy: .public) (conn=\(self.tag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        Self.logger.log(
            .notice,
            "Asked '\(self.peerName, privacy: .public)' to name the promised items of gen=\(generation, privacy: .public) (conn=\(self.tag, privacy: .public))"
        )
        return true
    }

    /// Calls off the drop or drag the peer has withdrawn, keeping whatever
    /// already landed, and tells the owner.
    ///
    /// The owner is told whether or not this side still held the generation:
    /// a take it is running on a drag already retired here still has to end.
    public func handleWithdrawal(generation: UInt64) {
        cancelInbound(generation: generation)
        onOfferRetracted(generation, .released)
    }

    /// Retires the drag for `generation` and tells the peer this side is done
    /// with it, waking any pull still parked on it as cancelled.
    ///
    /// Sent whether or not the drag is still held here: it is also how a take
    /// that failed before the guest caught the drag is abandoned, and the
    /// guest retires by generation. Best-effort.
    public func completeDrag(generation: UInt64) {
        // Whether or not the drag is held here: a naming still tracked for it
        // goes with it.
        dragNaming.retire(generation: generation)
        if callOff(generation: generation) {
            Self.logger.log(
                .notice,
                "Done with the drag from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public))"
            )
        }
        session.sendDragComplete(generation: generation)
    }

    /// Takes on what the peer reported about a gesture made on its side.
    ///
    /// A `clipboard.*` code is the peer's paste refusing; the refusal it becomes
    /// lands wherever this side's surface puts one.
    public func handlePeerError(_ error: Kernova_V1_Error) {
        Self.logger.log(
            .warning,
            "Clipboard error from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)): \(error.code, privacy: .public) — \(error.message, privacy: .public)"
        )
        guard error.code.hasPrefix("clipboard.") else { return }
        let code = ClipboardErrorCode(rawValue: error.code)
        onRefusal(
            .peerPaste,
            code == .pasteTooLarge ? .tooLarge(limitBytes: maxPasteBytes()) : .peerReported(code))
    }

    /// Forgets one offer and everything it holds, telling the peer nothing — the
    /// gesture it belonged to is over.
    ///
    /// A drop's entry is a finished job rather than a promise something still
    /// advertises, so nothing is left to serve from it.
    public func retire(generation: UInt64) {
        guard let entry = entries.removeValue(forKey: generation) else { return }
        if currentGeneration == generation { currentGeneration = 0 }
        releaseDrag(generation: generation)
        for waiter in entry.joinedWaiters.values { _ = coordinator.leave(waiter) }
        _ = takeSyncPulls(generation: generation)
    }

    /// Takes over a data connection this side's listener accepted, matching it
    /// to the pull awaiting the transfer its reply names.
    ///
    /// Takes ownership of `fd`: a reply naming a transfer nothing is awaiting
    /// closes it, which is the refusal the peer sees.
    ///
    /// `nonisolated`: this runs on the thread that read the reply, because a
    /// paste fire parked on the pull it answers can be holding the main
    /// thread.
    nonisolated public func adoptDataConnection(
        fd: Int32, reply: Kernova_V1_ClipboardTransferReply
    ) {
        guard let inbox = session.inbox else {
            ClipboardDataConnection.end(fd: fd)
            return
        }
        inbox.adopt(fd: fd, reply: reply)
    }

    /// Forgets the live offer without telling the peer — the buffer it was
    /// published into holds something else now.
    public func discardInboundOffer() {
        guard entries.removeValue(forKey: currentGeneration) != nil else { return }
        currentGeneration = 0
    }

    /// Bounds a peer's declared metadata before any of it reaches budget,
    /// capacity or progress arithmetic.
    private func boundedReps(
        _ reps: [Kernova_V1_ClipboardRepresentationInfo], generation: UInt64
    ) -> [Kernova_V1_ClipboardRepresentationInfo] {
        let bounded = ClipboardOfferBounds.bounded(reps)
        if let truncatedFrom = bounded.truncatedFrom {
            Self.logger.log(
                .warning,
                "Offer from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public)) declared \(truncatedFrom, privacy: .public) representations — truncated to \(bounded.reps.count, privacy: .public)"
            )
        }
        if bounded.clampedCount > 0 {
            Self.logger.log(
                .warning,
                "Clamped \(bounded.clampedCount, privacy: .public) implausible declared byte count(s) in the offer from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public))"
            )
        }
        return bounded.reps
    }

    /// Drops the live offer and tells the owner what became of it.
    ///
    /// The superseded generation's staged files are NOT swept — they ride the
    /// `maxGenerations` grace window, so a paste still being copied out, or a
    /// re-paste of an already-vended URL, survives the peer's next copy —
    /// docs/CLIPBOARD.md, "Pay on consume".
    private func retireCurrentOffer(reason: RetractReason) {
        let previous = entries[currentGeneration]
        if let previous {
            // Wakes every pull of the retired generation, whether or not its
            // transfer ever opened, so nothing parks to its backstop.
            session.inbox?.cancel(generation: previous.generation)
            entries[previous.generation] = nil
        }
        currentGeneration = 0
        onOfferRetracted(previous?.generation, reason)
    }

    // MARK: - Ending the connection

    /// Wakes every parked pull because the connection is over.
    ///
    /// A clipboard offer and its materialization cache stay: a pasteboard write
    /// this side published outlives the session behind it, and every
    /// representation already pulled stays servable from the cache and the
    /// staged files — docs/CLIPBOARD.md, "Pay on consume". A drop's or a drag's
    /// entries go — nothing on this side advertises them, and the jobs they
    /// belonged to end with the channel.
    ///
    /// `nonisolated` so the channel's own end can run it before anything hops to
    /// main — a pull parked on the main thread is what would block that hop. The
    /// retirement is left to a later main turn for the same reason.
    nonisolated public func endSession() {
        coordinator.failAll()
        dragNaming.endSession()
        for readiness in dragReadiness.withLock({ Array($0.values) }) {
            for latch in readiness.pending.values { latch.open() }
        }
        guard discipline.retiresOnSessionEnd else { return }
        MainActorBridge.async {
            for generation in Array(self.entries.keys) { self.retire(generation: generation) }
        }
    }

    /// Stops the pulls an owner's readout started for `generation`, leaving one
    /// another gesture is also waiting on.
    ///
    /// Leaving is the whole step: its answer is whether this side is done with
    /// the transfer, and the last waiter out retires the pull's slot, which runs
    /// the `retire` hook that deregisters the awaiter and closes this side's end
    /// of the connection — so the peer's next write fails and it stops producing
    /// bytes for a pull nothing is waiting on.
    public func cancelJoinedPulls(generation: UInt64) {
        guard let entry = entries[generation] else { return }
        for waiter in entry.joinedWaiters.values { _ = coordinator.leave(waiter) }
        Self.logger.log(
            .notice,
            "User cancelled the inbound transfer from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// Calls off everything `generation` has in flight and retires it.
    ///
    /// Order matters: deregister the awaiter, stop the peer producing bytes, then
    /// wake the parked caller. Waking it first would let it start the next
    /// representation before the cancellation is visible.
    public func cancelInbound(generation: UInt64) {
        guard callOff(generation: generation) else { return }
        Self.logger.log(
            .notice,
            "Cancelled the inbound transfer from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public))"
        )
    }

    /// Retires `generation` and wakes every pull it has in flight as
    /// cancelled, reporting whether it was held at all.
    private func callOff(generation: UInt64) -> Bool {
        guard let entry = entries.removeValue(forKey: generation) else { return false }
        if currentGeneration == generation { currentGeneration = 0 }
        releaseDrag(generation: generation)
        for waiter in entry.joinedWaiters.values { _ = coordinator.leave(waiter) }
        for id in takeSyncPulls(generation: generation) {
            session.inbox?.cancelAwait(id)
            coordinator.abort(
                id,
                ClipboardStreamAbortInfo(
                    transferID: id, code: .cancelled, message: "Cancelled by the user",
                    neededBytes: nil, availableBytes: nil))
        }
        return true
    }

    // MARK: - Pulling

    /// Starts or joins the pull for one representation without holding a thread,
    /// caching what it delivers.
    ///
    /// `operation` is the caller's readout, which a failure finishes with the
    /// reason for it. A representation already cached is answered from the
    /// cache and begins no transfer on `operation`: one declared but never fed
    /// would sit in its denominator waiting on events that never arrive.
    ///
    /// - Returns: the representation, now in `generation`'s cache — or `nil`
    ///   when nothing was delivered, or the offer was retired (superseded or
    ///   released) before the delivery settled, so nothing is cached for it.
    public func join(
        generation: UInt64, repIndex: Int, operation: ClipboardTransferOperation
    ) async -> ClipboardContent.Representation? {
        if let latch = pendingItemLatch(generation: generation, repIndex: repIndex) {
            #if DEBUG
            sizeWaitBeganForTesting.withLock { $0 }?()
            #endif
            operation.sizeWaitBegan()
            await latch.opened()
            operation.sizeWaitEnded()
        }
        let plan: PullPlan
        switch resolve(generation: generation, repIndex: repIndex, servesFileURL: false) {
        case .cached(let representation, _): return representation
        case .refused: return nil
        case .ready(let ready): plan = ready
        }
        operation.unitBegan(
            id: UInt64(repIndex), expectedBytes: plan.byteCount, name: plan.unitName)
        if let refusal = preflight(plan) {
            return settle(refusal, plan: plan, operation: operation, caller: .join)
        }
        let outcome: LazyPullOutcome = await withCheckedContinuation { continuation in
            let waiter = coordinator.join(
                transferID: plan.transferID, timeout: lazyPullTimeout,
                onProgress: progressHandler(plan, operation: operation),
                retire: { plan.inbox.cancelAwait(plan.transferID) },
                start: { self.begin(plan) },
                // Resumed from whichever thread resolved the pull — never routed
                // through main, which a paste fire may be holding.
                onResolve: { continuation.resume(returning: $0) })
            entries[generation]?.joinedWaiters[repIndex] = waiter
        }
        entries[generation]?.joinedWaiters[repIndex] = nil
        #if DEBUG
        await afterInboundPullForTesting?()
        #endif
        let representation = settle(outcome, plan: plan, operation: operation, caller: .join)
        guard entries[generation] != nil else { return nil }
        return representation
    }

    /// Starts or joins the pull for one representation, holding the calling
    /// thread until it resolves.
    ///
    /// The caller owns both `operation` and the outcome: it reports what a
    /// failure means in its own vocabulary, since a drop's answer crosses the
    /// wire as a `DropComplete` rather than a refusal. Callable from any thread
    /// but the main one inside a tracking loop — an `NSFilePromiseProvider`
    /// operation queue among them.
    ///
    /// Safe to call on the main thread: the receiver resolves the pull off-main,
    /// and on the main run loop's base the wait runs the event loop rather than
    /// parking. Where that wait is unavailable — a tracking or modal loop owns
    /// the events — the main thread is refused rather than parked, and nothing
    /// is served (`LazyPullCoordinator`).
    ///
    /// A drag's folder or promised item whose size has not arrived is held the
    /// same way until the size arrives or the drag ends, then pulled;
    /// `operation` reads the hold as a transfer whose total is not yet known.
    /// One the peer said will never be sized is refused `.unavailable`.
    nonisolated public func pull(
        generation: UInt64, repIndex: Int, operation: ClipboardTransferOperation
    ) -> LazyPullOutcome {
        if let latch = pendingItemLatch(generation: generation, repIndex: repIndex) {
            #if DEBUG
            sizeWaitBeganForTesting.withLock { $0 }?()
            #endif
            operation.sizeWaitBegan()
            let refused = coordinator.hold(until: latch)
            operation.sizeWaitEnded()
            if let refused { return refused }
        }
        let plan: PullPlan
        switch MainActorBridge.sync({
            self.resolve(generation: generation, repIndex: repIndex, servesFileURL: false)
        }) {
        case .cached(let representation, _): return .delivered(representation)
        case .refused(let outcome): return outcome
        case .ready(let ready): plan = ready
        }
        return runSyncPull(plan, operation: operation, caller: .caller)
    }

    /// The latch a pull of `(generation, repIndex)` waits on: set while it
    /// names a drag's folder or promised item whose size has not arrived,
    /// `nil` otherwise.
    nonisolated private func pendingItemLatch(generation: UInt64, repIndex: Int) -> OneShotLatch? {
        guard let latch = dragReadiness.withLock({ $0[generation]?.pending[repIndex] }),
            !latch.isOpen
        else { return nil }
        Self.logger.log(
            .notice,
            "Pull of rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)) waits for its size"
        )
        return latch
    }

    // MARK: - Serving a paste

    /// Serves the pasteboard `.fileURL` for a promised representation at paste
    /// time: the materialization cache first, else a deadline-bound pull.
    ///
    /// Safe to call on the main thread even though it blocks; where the
    /// event-loop wait is unavailable there it serves nothing rather than
    /// parking (`LazyPullCoordinator`).
    nonisolated public func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
        let plan: PullPlan
        switch MainActorBridge.sync({
            self.resolve(generation: generation, repIndex: repIndex, servesFileURL: true)
        }) {
        case .cached(let representation, let staged):
            return fileURL(
                for: representation, generation: generation, repIndex: repIndex, staged: staged)
        case .refused: return nil
        case .ready(let ready): plan = ready
        }
        guard let representation = pullUnderOwnOperation(plan) else { return nil }
        return fileURL(
            for: representation, generation: generation, repIndex: repIndex, staged: nil)
    }

    /// Serves an inline pasteboard flavor's bytes for a promised representation
    /// at paste time: the materialization cache first, else a pull.
    ///
    /// Inline representations are exempt from the paste-budget cap — Kernova
    /// imposes no size cap on inline content — docs/CLIPBOARD.md, "No
    /// Kernova-imposed size bound".
    ///
    /// Safe to call on the main thread even though it blocks; where the
    /// event-loop wait is unavailable there it serves nothing rather than
    /// parking (`LazyPullCoordinator`).
    nonisolated public func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        let plan: PullPlan
        switch MainActorBridge.sync({
            self.resolve(
                generation: generation, repIndex: repIndex, servesFileURL: false, expectedUTI: uti)
        }) {
        case .cached(let representation, _): return Self.residentBytes(of: representation)
        case .refused: return nil
        case .ready(let ready): plan = ready
        }
        return pullUnderOwnOperation(plan).flatMap(Self.residentBytes(of:))
    }

    /// Runs one paste-time pull under a readout of its own — a paste has no other
    /// operation to join.
    ///
    /// The operation is not cancellable: it spans one provider fire, and the
    /// pasteboard fires once per item, so a Cancel could stop only the item in
    /// flight while the consumer moves on to the next.
    nonisolated private func pullUnderOwnOperation(
        _ plan: PullPlan
    ) -> ClipboardContent.Representation? {
        let operation = ClipboardTransferOperation(
            gesture: .paste, direction: .inbound, peerName: peerName,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap, reporter: reporter)
        guard
            case .delivered(let representation) = runSyncPull(
                plan, operation: operation, caller: .paste)
        else {
            // Retired rather than finished: what a failed fire owes the user has
            // gone to the surface that owns refusals, and the readout has nothing
            // left to say about a transfer that ended.
            operation.abandon()
            return nil
        }
        operation.finish(.completed)
        return representation
    }

    /// Whether a `.fileURL` fire must be refused because the session stopped with
    /// the offer's file set only partly materialized.
    ///
    /// All-or-nothing, so a multi-file paste after the connection ends never
    /// silently lands a subset of the copied files. The file set is the offer's
    /// `.fileURL`-serving representations, the ones a Finder paste creates files
    /// from; a fully materialized set keeps serving from the cache and the staged
    /// files, and inline flavors keep serving regardless.
    private func refusesPasteBoundFire(generation: UInt64) -> Bool {
        // Keyed on the inbox being gone rather than on the session having
        // ended: a channel that closed under a live session can still serve
        // everything it holds, while a stopped one has no way left to reach the
        // unmaterialized siblings.
        guard session.inbox == nil, let entry = entries[generation] else { return false }
        let fileSet = entry.reps.indices.filter { ClipboardPromisePolicy.servesFileURL(entry.reps[$0]) }
        guard fileSet.contains(where: { entry.materialized[$0] == nil }) else { return false }
        Self.logger.log(
            .warning,
            "Paste fired for gen=\(generation, privacy: .public) of '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)) after the session ended with the file set partly materialized — \(ClipboardErrorCode.pasteIncompleteSet.rawValue, privacy: .public); serving nothing"
        )
        // The N fires of one multi-file paste each report the same refusal; the
        // surface it lands on absorbs the repeats into one message.
        onRefusal(.paste, .incompleteFileSet)
        return true
    }

    // MARK: - The pull core

    /// Everything one pull needs, snapshotted in the single main-actor hop a
    /// blocking caller makes before it holds a thread.
    private struct PullPlan: Sendable {
        let generation: UInt64
        let repIndex: Int
        let transferID: UInt64
        let uti: String
        let byteCount: UInt64
        /// Non-`nil` for a folder: the archive is its tree, extracted into a
        /// folder of that name as it streams.
        let extractsDirectoryNamed: String?
        let filename: String
        /// What the receive volume must have room for before a byte is
        /// requested, or `nil` when nothing about this pull lands on disk.
        let preflightByteCount: Int?
        let inbox: ClipboardTransferInbox
        /// Opens this transfer's data connection when this side is the one that
        /// dials; `nil` when it accepts instead and asks over the control
        /// channel.
        let dial: (@Sendable () throws -> Int32)?

        var unitName: String? { filename.isEmpty ? nil : filename }

        /// What the receiving side expects of the transfer.
        var receivePlan: ClipboardTransferReceiver.Plan {
            ClipboardTransferReceiver.Plan(
                uti: uti, filename: filename, extractsDirectoryNamed: extractsDirectoryNamed,
                advertisedByteCount: Int(clamping: byteCount))
        }
    }

    /// What a resolved pull request turned out to be.
    private enum Resolution: Sendable {
        /// Already materialized; `stagedURL` is the temp file an inline payload
        /// was staged into for an earlier `.fileURL` fire, if any.
        case cached(ClipboardContent.Representation, stagedURL: URL?)
        /// Nothing will be pulled; the reason has already been logged and, where
        /// one is owed, reported.
        case refused(LazyPullOutcome)
        case ready(PullPlan)
    }

    /// Who is pulling, which decides what a failure owes and to whom.
    private enum PullCaller {
        /// An async join under the caller's readout.
        case join
        /// A synchronous pull whose caller maps the outcome itself.
        case caller
        /// A paste-time provider fire under a readout this object owns.
        case paste
    }

    /// Validates that `(generation, repIndex)` still addresses a live offer and
    /// snapshots what pulling it needs.
    ///
    /// The single site every fire passes through — and the only main-actor hop a
    /// blocking one makes before its wait — so each refusal logs why it serves
    /// nothing, since a provider fire has no other surface. A stale generation
    /// logs `.debug` (the benign supersession race: the newer offer's own
    /// publication is what retires these promises); the other misses persist as
    /// `.warning`.
    ///
    /// `servesFileURL` says the caller is a `.fileURL` fire: the flavor the
    /// paste-bound rules govern, and the one that lands on disk whether or not
    /// the representation is inline.
    private func resolve(
        generation: UInt64, repIndex: Int, servesFileURL: Bool, expectedUTI: String? = nil
    ) -> Resolution {
        // Post-stop all-or-nothing: a partially materialized file set serves no
        // file at all rather than a silent subset, cached siblings included.
        if servesFileURL, refusesPasteBoundFire(generation: generation) {
            return .refused(.cancelled)
        }
        guard let entry = entries[generation] else {
            logMissingOffer(generation: generation, repIndex: repIndex)
            return .refused(.cancelled)
        }
        guard entry.reps.indices.contains(repIndex) else {
            Self.logger.log(
                .warning,
                "Pull requested out-of-range rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)) — serving nothing"
            )
            return .refused(.cancelled)
        }
        if let cached = entry.materialized[repIndex] {
            logCacheHit(cached, generation: generation, repIndex: repIndex)
            return .cached(cached, stagedURL: entry.stagedInlineURLs[repIndex])
        }
        switch dragReadiness.withLock({ $0[generation] }) {
        case let readiness? where readiness.pending[repIndex] != nil:
            Self.logger.log(
                .warning,
                "Pull requested rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)), whose size never arrived — serving nothing"
            )
            return .refused(.cancelled)
        case let readiness? where readiness.unavailable.contains(repIndex):
            Self.logger.log(
                .warning,
                "Pull requested rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)), which the peer could not produce — \(ClipboardErrorCode.dragItemUnavailable.rawValue, privacy: .public); serving nothing"
            )
            return .refused(.unavailable)
        default:
            break
        }
        guard let inbox = session.inbox else {
            Self.logger.log(
                .warning,
                "Pull requested un-materialized rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)) after the session ended — serving nothing"
            )
            return .refused(.cancelled)
        }
        let info = entry.reps[repIndex]
        guard expectedUTI == nil || expectedUTI == info.uti else { return .refused(.cancelled) }
        if servesFileURL, let budget = pasteBudget(generation: generation), budget.exceeds {
            refusePasteBudget(budget, entry: entry)
            return .refused(.cancelled)
        }
        let transferID = self.transferID(generation: generation, repIndex: repIndex)
        syncPulls.withLock { _ = $0.insert(transferID) }
        #if DEBUG
        pullsStartedForTesting += 1
        #endif
        return .ready(
            PullPlan(
                generation: generation, repIndex: repIndex, transferID: transferID, uti: info.uti,
                byteCount: info.byteCount,
                extractsDirectoryNamed: info.isDirectory ? info.filename : nil,
                filename: info.filename,
                // Every representation that stages to disk is checked, plus the
                // `.fileURL` flavor of an inline one — its bytes reassemble in
                // memory and are then staged for the URL a paste creates the file
                // from.
                preflightByteCount: !info.isInline || servesFileURL
                    ? Int(clamping: info.byteCount) : nil,
                inbox: inbox, dial: session.dataDialer))
    }

    /// Records a pull for a generation this side no longer holds.
    ///
    /// Only a clipboard promise with nothing live behind it persists: a drop's
    /// or a drag's entry is retired the moment its job ends, so a pull for one
    /// that is gone is the ordinary tail of a cancelled or completed job, and a
    /// superseded clipboard generation is the benign supersession race — the
    /// newer offer's own publication is what retires those promises.
    private func logMissingOffer(generation: UInt64, repIndex: Int) {
        guard discipline.supersedes, currentGeneration == 0 else {
            Self.logger.log(
                .debug,
                "Pull requested rep \(repIndex, privacy: .public) of retired gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (live gen=\(self.currentGeneration, privacy: .public), conn=\(self.tag, privacy: .public)) — serving nothing"
            )
            return
        }
        Self.logger.log(
            .warning,
            "Pull requested rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.tag, privacy: .public)) with no live offer — serving nothing"
        )
    }

    /// Refuses the whole file set, on the surface each side owes it.
    ///
    /// One paste is one deadline-bound operation, so the OS clock sees the sum
    /// rather than each file: a set over the cap is refused whole rather than
    /// landing 2 of 3 files.
    private func refusePasteBudget(_ budget: ClipboardPromisePolicy.PasteBudget, entry: Entry) {
        Self.logger.log(
            .warning,
            "Paste refused: \(ClipboardErrorCode.copyTooLarge.rawValue, privacy: .public) — paste-bound reps total \(budget.total, privacy: .public) bytes, over the \(budget.limit, privacy: .public)-byte cap; refusing the whole file set"
        )
        onRefusal(.copy, .tooLarge(limitBytes: budget.limit))
        announceRefusal(
            .pasteTooLarge, "Too large to paste (\(budget.total) bytes total)", entry: entry)
    }

    /// Runs one synchronous pull to its outcome.
    nonisolated private func runSyncPull(
        _ plan: PullPlan, operation: ClipboardTransferOperation, caller: PullCaller
    ) -> LazyPullOutcome {
        operation.unitBegan(
            id: UInt64(plan.repIndex), expectedBytes: plan.byteCount, name: plan.unitName)
        if let refusal = preflight(plan) {
            settle(refusal, plan: plan, operation: operation, caller: caller)
            return refusal
        }
        let outcome = coordinator.pull(
            transferID: plan.transferID, timeout: lazyPullTimeout,
            onProgress: progressHandler(plan, operation: operation),
            retire: { plan.inbox.cancelAwait(plan.transferID) },
            start: { self.begin(plan) })
        settle(outcome, plan: plan, operation: operation, caller: caller)
        return outcome
    }

    /// The free-space pre-flight, as the abort a failure reads as.
    ///
    /// Runs wherever the pull will land on disk (``PullPlan/preflightByteCount``)
    /// and nowhere else: an inline payload a caller only reads reassembles in
    /// memory, and Kernova caps neither — docs/CLIPBOARD.md, "No Kernova-imposed
    /// size bound". Raised as an abort so one outcome mapping covers a volume
    /// this side found full and one the peer did.
    ///
    /// `nonisolated`: it reads the thread-safe staging alone, and the statfs
    /// behind that has no business on the main thread.
    nonisolated private func preflight(_ plan: PullPlan) -> LazyPullOutcome? {
        guard let needed = plan.preflightByteCount,
            !staging.hasCapacity(forByteCount: needed)
        else { return nil }
        Self.logger.log(
            .warning,
            "Not enough disk space to receive rep '\(plan.uti, privacy: .public)' (\(plan.byteCount, privacy: .public) bytes)"
        )
        return .aborted(
            ClipboardStreamAbortInfo(
                transferID: plan.transferID, code: .diskFull,
                message: "Not enough disk space to receive \(plan.byteCount) bytes",
                neededBytes: needed,
                availableBytes: staging.availableCapacity().map { Int(clamping: $0) }))
    }

    /// Opens one pull: registers the transfer's awaiter, then asks for its bytes
    /// the way this side's role allows.
    ///
    /// The single place a pull begins, whichever gesture arrived first — so one
    /// awaiter and one ask cover every caller that joins it. On the dialling
    /// side the connection *is* the ask; on the accepting side a
    /// `ClipboardRequest` crosses the control channel and the peer dials back. A
    /// request that never leaves resolves the pull immediately rather than
    /// leaving it to the backstop.
    nonisolated private func begin(_ plan: PullPlan) {
        plan.inbox.awaitTransfer(
            plan.transferID,
            // A folder's bytes are an archive of its tree, extracted as they
            // arrive: the transfer learns that here, from the offer this side
            // already read, rather than from the wire — including the size the
            // extract is held to.
            plan: plan.receivePlan,
            onComplete: { [coordinator] in coordinator.deliver(plan.transferID, $0) },
            onAbort: { [coordinator] in coordinator.abort(plan.transferID, $0) },
            onProgress: { [coordinator] bytes, total in
                coordinator.progress(plan.transferID, bytesReceived: bytes, totalBytes: total)
            },
            onActivity: { [coordinator] in coordinator.recordActivity(plan.transferID) })
        // Read here rather than snapshotted with the plan: the statfs behind it
        // belongs off the main thread.
        let ceiling =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        if let dial = plan.dial {
            // A dial that fails resolves the transfer's own abort, so there is
            // nothing to catch here.
            plan.inbox.open(
                transferID: plan.transferID, generation: plan.generation,
                maxAcceptByteCount: ceiling, dial: dial)
            return
        }
        do {
            try session.sendRequest(
                generation: plan.generation, transferID: plan.transferID, uti: plan.uti,
                maxAcceptByteCount: ceiling)
        } catch {
            // No request went out, so no connection will arrive — resolve the
            // pull now instead of blocking to the backstop timeout.
            plan.inbox.cancelAwait(plan.transferID)
            Self.logger.log(
                .warning,
                "Failed to send the clipboard request: \(error.localizedDescription, privacy: .public)"
            )
            coordinator.abort(
                plan.transferID,
                ClipboardStreamAbortInfo(
                    transferID: plan.transferID, code: .sendFailed,
                    message: "Failed to send the clipboard request", neededBytes: nil,
                    availableBytes: nil))
        }
    }

    nonisolated private func progressHandler(
        _ plan: PullPlan, operation: ClipboardTransferOperation
    ) -> @Sendable (Int, Int) -> Void {
        { bytes, total in
            operation.unitProgressed(
                id: UInt64(plan.repIndex), bytesTransferred: UInt64(max(0, bytes)),
                totalBytes: UInt64(max(0, total)))
        }
    }

    /// Caches what a pull delivered, reports what it failed with, and ends the
    /// readout's unit.
    @discardableResult
    nonisolated private func settle(
        _ outcome: LazyPullOutcome, plan: PullPlan, operation: ClipboardTransferOperation,
        caller: PullCaller
    ) -> ClipboardContent.Representation? {
        syncPulls.withLock { _ = $0.remove(plan.transferID) }
        guard case .delivered(let representation) = outcome else {
            if caller == .paste {
                // Retired rather than ended: a readout this object owns has
                // nothing left to say about a fire that failed, and its
                // retirement is queued ahead of the refusal on the one serial
                // main queue both take — so what the refusal reports is what
                // stands. An ended unit would emit a running readout instead,
                // landing *after* the refusal and displacing it.
                operation.abandon()
            } else {
                operation.unitEnded(id: UInt64(plan.repIndex), succeeded: false)
            }
            report(outcome, plan: plan, operation: operation, caller: caller)
            return nil
        }
        // A dropped or dragged file is landed by its caller, never served
        // again, so caching it would only pin the staged copy it is about to
        // move — and the hop that cache costs is one its pull then never pays.
        if discipline.cachesMaterialized {
            MainActorBridge.sync {
                // The entry is re-read after the wait rather than captured before
                // it: a supersession can land inside the nested event loop a
                // main-thread fire runs, and caching into an offer nothing shows
                // any more would resurrect it.
                guard let entry = self.entries[plan.generation] else { return }
                if entry.materialized[plan.repIndex] == nil {
                    entry.materialized[plan.repIndex] = representation
                    entry.epoch += 1
                }
                self.onActivity(.representationReceived)
            }
        }
        operation.unitEnded(id: UInt64(plan.repIndex), succeeded: true)
        return representation
    }

    /// Reports what one pull's outcome owes, to the surfaces that side owes it
    /// on.
    ///
    /// Only a paste fire's own operation, which this object opened, reports a
    /// failure: an operation the caller owns spans more than this pull — the
    /// host's preview loop shares one across every representation it fetches —
    /// so ending it on one stalled representation would leave the rest streaming
    /// into a dead readout. The exception is an abort a joined pull maps to a
    /// failure, which is the whole account that loop gets of a chip that never
    /// filled in.
    nonisolated private func report(
        _ outcome: LazyPullOutcome, plan: PullPlan, operation: ClipboardTransferOperation,
        caller: PullCaller
    ) {
        // The caller reports in its own vocabulary — a drop's answer crosses as a
        // `DropComplete`, not as a refusal.
        guard caller != .caller || outcome.isTimedOut else { return }
        switch outcome {
        case .delivered:
            break
        case .aborted(let info):
            Self.logger.log(
                .warning,
                "Inbound pull \(plan.transferID, privacy: .public) (conn=\(self.tag, privacy: .public)) aborted (\(info.rawCode, privacy: .public))"
            )
            guard let failure = ClipboardTransferFailure.inboundPullAborted(info) else {
                // A retiring abort names no failure of its own; only the end of
                // this connection has nothing else to explain it.
                recordInterruption(caller: caller)
                return
            }
            switch caller {
            case .join: operation.finish(.failed(failure))
            case .paste: raiseRefusal(.paste, failure)
            case .caller: break
            }
            announceRefusal(
                Self.pasteErrorCode(forAbortCode: info.code), info.message, generation: plan.generation,
                caller: caller)
        case .timedOut:
            Self.logger.log(
                .warning,
                "Inbound pull \(plan.transferID, privacy: .public) (conn=\(self.tag, privacy: .public)) timed out"
            )
            // Nothing is sent to stop the peer: the coordinator's own retirement
            // released the awaiter and closed the transfer's connection, which
            // is what stops it producing bytes.
            guard caller == .paste else { return }
            raiseRefusal(.paste, .timedOut)
            announceRefusal(
                .pasteTimeout, "The clipboard transfer timed out", generation: plan.generation, caller: caller)
        case .cancelled:
            // `.debug`, not `.warning`: a cancellation also covers the benign
            // teardown and supersession.
            Self.logger.log(
                .debug,
                "Inbound pull \(plan.transferID, privacy: .public) (conn=\(self.tag, privacy: .public)) cancelled"
            )
            recordInterruption(caller: caller)
        case .mainThreadUnavailable:
            Self.logger.log(
                .warning,
                "Inbound pull \(plan.transferID, privacy: .public) (conn=\(self.tag, privacy: .public)) refused: the fire holds the main thread where the event-loop wait is unavailable — serving nothing rather than freezing the app"
            )
            guard caller == .paste else { return }
            raiseRefusal(.paste, .transferFailed)
            announceRefusal(
                .pasteFailed, "The paste could not be served from this window",
                generation: plan.generation, caller: caller)
        case .unavailable:
            // Refused in `resolve`, before any pull began, so nothing settles it.
            break
        }
    }

    /// Explains a paste fire this connection's end cut short: the fire serves
    /// nothing, and unlike a supersession nothing else says why.
    ///
    /// The N fires of one multi-file paste each report the same refusal; the
    /// surface it lands on absorbs the repeats into one message.
    nonisolated private func recordInterruption(caller: PullCaller) {
        guard caller == .paste, session.hasEnded else { return }
        raiseRefusal(.paste, .interrupted(fileCount: nil))
    }

    // MARK: - Refusals

    /// Hands one refusal to the surface that owns it, from whichever thread
    /// raised it.
    ///
    /// Queued rather than run inline, even on the main thread: a readout
    /// publishes through the serial main queue, so a refusal that ran inline
    /// would be recorded ahead of emissions its own operation queued earlier
    /// and be displaced by them.
    nonisolated private func raiseRefusal(
        _ gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure
    ) {
        MainActorBridge.async { self.onRefusal(gesture, failure) }
    }

    /// Maps a receiver or peer abort code to the user-facing paste code the peer
    /// renders.
    nonisolated private static func pasteErrorCode(
        forAbortCode code: ClipboardStreamAbortCode?
    ) -> ClipboardErrorCode {
        switch code {
        case .diskFull: return .pasteDiskFull
        case .stallTimeout: return .pasteTimeout
        default: return .pasteFailed
        }
    }

    nonisolated private func announceRefusal(
        _ code: ClipboardErrorCode, _ message: String, generation: UInt64, caller: PullCaller
    ) {
        guard caller == .paste else { return }
        MainActorBridge.sync {
            guard let entry = self.entries[generation] else { return }
            self.announceRefusal(code, message, entry: entry)
        }
    }

    /// Reports an inbound-paste failure on both surfaces the gesture is owed: the
    /// menu of the side the paste was made on, and an `Error` frame so the peer's
    /// clipboard window shows it too.
    ///
    /// Deduped by the offer's refusal-burst window — one paste fires one provider
    /// per promised item, so its failures are reported once, while a later paste
    /// of the same offer is a fresh gesture and reports again.
    private func announceRefusal(_ code: ClipboardErrorCode, _ message: String, entry: Entry) {
        guard sendsPasteRefusalsToPeer, opensRefusalWindow(entry) else { return }
        session.sendError(code: code, message: message, inReplyTo: "clipboard.request")
        recordRefusal(code, generation: entry.generation)
    }

    /// Puts the refusal on this side's own surface, once the fire that raised it
    /// has returned.
    ///
    /// Deferred rather than written inline: the fire's own wait runs the main
    /// event loop, so an offer that landed inside it is live and pastable and
    /// must not be relabelled with the previous offer's failure.
    func recordRefusal(_ code: ClipboardErrorCode, generation: UInt64) {
        MainActorBridge.async {
            guard self.currentGeneration == generation else { return }
            // The ceiling is read now: a peer that raises it after this refusal
            // must not rewrite the figure the refusal named.
            self.onActivity(
                .pasteRefused(
                    code, limitBytes: code == .pasteTooLarge ? self.maxPasteBytes() : nil))
        }
    }

    /// Whether a refusal for `entry` may be reported now, opening the burst
    /// window when it may.
    private func opensRefusalWindow(_ entry: Entry) -> Bool {
        let now = clock.now
        if let last = entry.lastRefusalReportedAt,
            last.seconds(to: now) < Self.refusalBurstWindow
        {
            return false
        }
        entry.lastRefusalReportedAt = now
        return true
    }

    // MARK: - Serving a materialized representation

    /// The `public.file-url` value for a materialized representation: the staged
    /// file or extracted folder when one exists, else its resident bytes staged
    /// once and re-served from then on.
    ///
    /// A folder arrives already unpacked — its transfer extracted the tree as the
    /// archive streamed — so serving it costs nothing inside the paste deadline,
    /// and a repeated paste re-serves the same tree.
    ///
    /// `staged` is what an earlier fire of this representation staged, read in the
    /// resolving hop; a fire that just pulled the bytes has none.
    nonisolated private func fileURL(
        for representation: ClipboardContent.Representation, generation: UInt64, repIndex: Int,
        staged: URL?
    ) -> URL? {
        if let url = representation.fileURL { return url }
        if let staged, FileManager.default.fileExists(atPath: staged.path) { return staged }
        guard let data = representation.inMemoryData,
            let sink = try? staging.makeSink(
                generation: generation, filename: representation.filename)
        else {
            Self.logger.log(
                .error,
                "Failed to stage '\(representation.filename, privacy: .public)' from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public)) — serving nothing"
            )
            raiseRefusal(.paste, .stagingFailed)
            return nil
        }
        do {
            try sink.write(data)
            let url = try sink.commit()
            MainActorBridge.sync { self.entries[generation]?.stagedInlineURLs[repIndex] = url }
            return url
        } catch {
            // Don't offer a truncated file — abort the partial stage.
            sink.abort()
            Self.logger.log(
                .error,
                "Failed to write staged file '\(representation.filename, privacy: .public)' from '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            raiseRefusal(.paste, .stagingFailed)
            return nil
        }
    }

    /// Resident bytes for an inline flavor, memory-mapped from the staged file
    /// when the payload spilled, so a multi-GB representation is never loaded
    /// into the heap.
    nonisolated private static func residentBytes(
        of representation: ClipboardContent.Representation
    ) -> Data? {
        if let resident = representation.inMemoryData { return resident }
        guard let url = representation.fileURL else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    nonisolated private func logCacheHit(
        _ representation: ClipboardContent.Representation, generation: UInt64, repIndex: Int
    ) {
        Self.logger.log(
            .debug,
            "Served rep \(repIndex, privacy: .public) (gen=\(generation, privacy: .public), conn=\(self.tag, privacy: .public), '\(representation.uti, privacy: .public)') from cache — no transfer"
        )
    }

    // MARK: - Plumbing

    /// The `transfer_id` of an inbound pull: the receiver mints it, so the host
    /// sets the direction bit and the guest does not. [H3]
    nonisolated private func transferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: session.role == .host)
    }
}

extension LazyPullOutcome {
    /// Whether the pull ended because nothing arrived inside its inactivity
    /// window.
    fileprivate var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }
}
