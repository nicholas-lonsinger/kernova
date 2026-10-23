import Foundation

/// How the offers travelling one way on one channel behave, derived once from
/// the channel and the end that sends them.
///
/// Three flows share the offer tables: clipboard offers in either direction on
/// the clipboard channel, and on the drop channel the host's drops and the
/// guest's drags out. Each table reads a behavior off a field here rather than
/// branching on the channel, so what makes a flow different is stated once.
struct ClipboardOfferDiscipline: Equatable, Sendable {
    /// Which of the three flows this is — the frame vocabulary it speaks.
    enum Flow: Equatable, Sendable {
        /// Clipboard offers, either direction.
        case clipboard
        /// Files dropped on the VM display, host→guest.
        case drop
        /// Files dragged out of the VM display, guest→host.
        case dragOut
    }

    /// When the sending side's readout of an offer opens, and what ends it.
    enum Readout: Equatable, Sendable {
        /// One readout for the offer the peer is pulling, opened on its first
        /// request and replaced by the next offer's — never more than one.
        case sharedPeerPaste
        /// One per offer, opened with the offer and spanning its whole set;
        /// the peer's verdict ends it.
        case upFront
        /// One per offer, opened on the peer's first request and ended by its
        /// pulls going idle, so concurrent offers never abandon each other's.
        case perEntryOnFirstRequest
    }

    let flow: Flow

    // MARK: Sending side

    /// A new offer retires the one before it: the peer holds one at a time.
    let supersedes: Bool
    /// Content identical to what was last announced is not offered again.
    let dedups: Bool
    /// The sending side's readout of each offer.
    let readout: Readout
    /// The gesture the sending side's readout reports.
    let servingGesture: ClipboardTransferGesture
    /// An offer the peer never pulls, or stops pulling, is called off after
    /// ``ClipboardStreamTuning/dropClaimTimeout``, and the peer serves one at a
    /// time.
    let hasClaimDeadline: Bool
    /// The peer's verdict frame settles each offer, and the owner hears of the
    /// settle so it can free what it staged for it.
    let reportsSettle: Bool
    /// An offer still open when the session ends fails its readout as
    /// interrupted, rather than abandoning it.
    let failsOnSessionEnd: Bool
    /// A Cancel on the readout retires the whole offer and tells the peer,
    /// rather than calling off only the transfers in flight.
    let cancelRetiresOffer: Bool
    /// The owner may withdraw any live offer by generation.
    let ownerWithdraws: Bool
    /// A representation may cross inline, for a pasteboard; otherwise every one
    /// lands as a file.
    let servesInline: Bool
    /// Every readout unit carries its item's filename.
    let namesEveryUnit: Bool

    // MARK: Receiving side

    /// What a pull delivered is cached against its offer and served again.
    let cachesMaterialized: Bool
    /// The offers this side holds go with the session that brought them.
    let retiresOnSessionEnd: Bool
    /// How long the staging this side's pulls fill lives.
    ///
    /// A clipboard offer replaces the last and a drop's jobs pull one at a
    /// time, so the newest few generations cover every live reader; drags out
    /// pull concurrently, so each keeps its folder until its take discards it.
    let stagingRetention: ClipboardFileStaging.Retention

    /// The discipline of the offers `sender` makes on `kind`'s channel.
    init(kind: ClipboardControlSession.Kind, sender: ClipboardControlSession.Role) {
        switch (kind, sender) {
        case (.clipboard, _):
            self.init(
                flow: .clipboard, supersedes: true, dedups: true, readout: .sharedPeerPaste,
                servingGesture: .peerPaste, hasClaimDeadline: false, reportsSettle: false,
                failsOnSessionEnd: false, cancelRetiresOffer: false, ownerWithdraws: false,
                servesInline: true, namesEveryUnit: false, cachesMaterialized: true,
                retiresOnSessionEnd: false,
                stagingRetention: .newest(ClipboardFileStaging.maxGenerations))
        case (.drop, .host):
            self.init(
                flow: .drop, supersedes: false, dedups: false, readout: .upFront,
                servingGesture: .drop, hasClaimDeadline: true, reportsSettle: true,
                failsOnSessionEnd: true, cancelRetiresOffer: true, ownerWithdraws: false,
                servesInline: false, namesEveryUnit: true, cachesMaterialized: false,
                retiresOnSessionEnd: true,
                stagingRetention: .newest(ClipboardFileStaging.maxGenerations))
        case (.drop, .guest):
            self.init(
                flow: .dragOut, supersedes: false, dedups: false,
                readout: .perEntryOnFirstRequest, servingGesture: .dragOut,
                hasClaimDeadline: false, reportsSettle: false, failsOnSessionEnd: false,
                cancelRetiresOffer: true, ownerWithdraws: true, servesInline: false,
                namesEveryUnit: true, cachesMaterialized: false, retiresOnSessionEnd: true,
                stagingRetention: .untilDiscarded)
        }
    }

    /// The discipline of the offers `receiver` takes from its peer on `kind`'s
    /// channel.
    init(kind: ClipboardControlSession.Kind, receiver: ClipboardControlSession.Role) {
        self.init(kind: kind, sender: receiver == .host ? .guest : .host)
    }

    private init(
        flow: Flow, supersedes: Bool, dedups: Bool, readout: Readout,
        servingGesture: ClipboardTransferGesture, hasClaimDeadline: Bool, reportsSettle: Bool,
        failsOnSessionEnd: Bool, cancelRetiresOffer: Bool, ownerWithdraws: Bool,
        servesInline: Bool, namesEveryUnit: Bool, cachesMaterialized: Bool,
        retiresOnSessionEnd: Bool, stagingRetention: ClipboardFileStaging.Retention
    ) {
        self.flow = flow
        self.supersedes = supersedes
        self.dedups = dedups
        self.readout = readout
        self.servingGesture = servingGesture
        self.hasClaimDeadline = hasClaimDeadline
        self.reportsSettle = reportsSettle
        self.failsOnSessionEnd = failsOnSessionEnd
        self.cancelRetiresOffer = cancelRetiresOffer
        self.ownerWithdraws = ownerWithdraws
        self.servesInline = servesInline
        self.namesEveryUnit = namesEveryUnit
        self.cachesMaterialized = cachesMaterialized
        self.retiresOnSessionEnd = retiresOnSessionEnd
        self.stagingRetention = stagingRetention
    }

    // MARK: - Vocabulary

    /// The frame announcing `reps` under `generation`.
    func offerFrame(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
    ) -> Frame {
        switch flow {
        case .clipboard:
            .clipboardOffer(generation: generation, reps: reps, isConcealed: isConcealed)
        case .drop: .dropOffer(generation: generation, reps: reps)
        case .dragOut: .dragOffer(generation: generation, reps: reps)
        }
    }

    /// The frame retiring the offer for `generation`.
    func releaseFrame(generation: UInt64) -> Frame {
        switch flow {
        case .clipboard: .clipboardRelease(generation: generation)
        case .drop: .dropRelease(generation: generation)
        case .dragOut: .dragRelease(generation: generation)
        }
    }

    /// The refusal message for a request naming no live offer.
    func staleMessage(generation: UInt64) -> String {
        switch flow {
        case .clipboard: "Request for superseded generation \(generation)"
        case .drop: "No live drop for generation \(generation)"
        case .dragOut: "No live drag for generation \(generation)"
        }
    }

    /// The refusal message for a request past the offer's last item.
    func rangeMessage(repIndex: Int) -> String {
        switch flow {
        case .clipboard: "Representation index \(repIndex) out of range"
        case .drop, .dragOut: "Item index \(repIndex) out of range"
        }
    }

    /// The refusal message for a request whose UTI is not the offered one.
    func utiMessage(uti: String) -> String {
        switch flow {
        case .clipboard: "Requested UTI '\(uti)' does not match offered representation"
        case .drop: "Requested UTI '\(uti)' does not match the dropped item"
        case .dragOut: "Requested UTI '\(uti)' does not match the dragged item"
        }
    }
}
