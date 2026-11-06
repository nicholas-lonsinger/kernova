#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaSynchronization
import KernovaWire

/// One item pull: the connection it runs on and its stream, on either side.
public struct ItemPullID: Hashable, Sendable {
    /// The connection the pull belongs to.
    public var generation: ConnectionGeneration
    /// The pull's stream.
    public var stream: StreamID

    /// Creates a pull id.
    public init(generation: ConnectionGeneration, stream: StreamID) {
        self.generation = generation
        self.stream = stream
    }
}

/// An item set as an offer stream carries it. An offer is refused `INTERNAL` unless its token is 16 bytes no
/// open offer of this side holds and its every representation is named as `Representation.name` requires.
public struct ItemOffer: Sendable, Equatable {
    /// The 16 bytes naming the offer, which a pull quotes.
    public var token: Data
    /// The receiver keeps the content out of history and logs.
    public var concealed: Bool
    /// The items, in the order they are sent.
    public var items: [OfferedItem]
    /// A peer's CLIPBOARD offer: the token of the last host clipboard offer it received on the connection,
    /// empty when none (`ItemSetHeader.after`); a copy's, the ask it answers. Empty on every other offer.
    public var after: Data
    /// What a CLIPBOARD offer is besides its opener's clipboard offer (`ItemSetHeader.copy`): a copy is not
    /// this side's clipboard offer, so a later one does not withdraw it.
    public var copy: ClipboardCopyRole
    /// A copy's: how many items of its opener's clipboard it does not carry whole
    /// (`ItemSetHeader.left_out`); 0 on every other offer.
    public var leftOut: Int

    /// Creates an offer.
    public init(
        token: Data, concealed: Bool = false, items: [OfferedItem], after: Data = Data(),
        copy: ClipboardCopyRole = .notACopy, leftOut: Int = 0
    ) {
        self.token = token
        self.concealed = concealed
        self.items = items
        self.after = after
        self.copy = copy
        self.leftOut = leftOut
    }
}

/// An item-set offer's header: what the far side's OPEN announced.
public struct ItemSetHeaderValue: Sendable, Equatable {
    /// The feature whose offer kind the OPEN named.
    public var feature: FeatureID
    /// The 16 bytes naming the offer, which a pull quotes.
    public var token: Data
    /// The receiver keeps the content out of history and logs.
    public var concealed: Bool
    /// The items the offer sends.
    public var count: Int
    /// ``ItemOffer/after``, as the OPEN carried it.
    public var after: Data
    /// ``ItemOffer/copy``, as the OPEN carried it.
    public var copy: ClipboardCopyRole
    /// ``ItemOffer/leftOut``, as the OPEN carried it.
    public var leftOut: Int

    /// A header announcing `count` items of `feature`'s offer `token`.
    public init(
        feature: FeatureID, token: Data, concealed: Bool, count: Int, after: Data = Data(),
        copy: ClipboardCopyRole = .notACopy, leftOut: Int = 0
    ) {
        self.feature = feature
        self.token = token
        self.concealed = concealed
        self.count = count
        self.after = after
        self.copy = copy
        self.leftOut = leftOut
    }

    init(_ header: Kernova_V2_ItemSetHeader, feature: FeatureID) {
        self.init(
            feature: feature, token: header.token, concealed: header.concealed, count: Int(header.count),
            after: header.after, copy: ClipboardCopyRole(header.copy), leftOut: Int(header.leftOut))
    }
}

/// What a CLIPBOARD offer is besides its opener's clipboard offer, sent because the user asked for a clipboard
/// on the far side.
public enum ClipboardCopyRole: Sendable, Equatable {
    /// The opener's clipboard offer, and every offer of another feature.
    case notACopy
    /// A snapshot of the opener's clipboard.
    case snapshot
    /// The host's ask for a snapshot of the peer's clipboard, of no items.
    case ask

    /// The role `wire` names; an unrecognized one is no copy.
    init(_ wire: Kernova_V2_ClipboardCopy) {
        switch wire {
        case .snapshot: self = .snapshot
        case .ask: self = .ask
        case .unspecified, .UNRECOGNIZED: self = .notACopy
        }
    }

    /// The wire's spelling.
    var wire: Kernova_V2_ClipboardCopy {
        switch self {
        case .notACopy: .unspecified
        case .snapshot: .snapshot
        case .ask: .ask
        }
    }
}

/// Whose offer an event is about: this side's or the far side's. Their tokens are separate namespaces.
public enum ItemOfferOrigin: Sendable, Equatable {
    /// This side offered it.
    case local
    /// The far side offered it.
    case remote
}

/// One pull of a representation of the far side's offer, where its sink lands it, and the budget the landing
/// draws on. The sink builds it, since what the request accepts — the decmpfs types above all — is what that
/// landing's volume reads back; nothing else can pair a request with a landing.
public struct ItemPullOrder: Sendable, Equatable {
    /// What the pull asks the far side for.
    public let request: PullRequest
    /// Where the sink lands it.
    public let landing: ItemLanding
    /// The budget the sink charges each landed entry's bytes to, shared with the owner's other pulls; nil
    /// when the request's byte ceiling is the only bound.
    public let budget: ByteBudget?

    /// Pairs `request` with `landing`, which the caller has made it accept, charging what lands to `budget`.
    package init(_ request: PullRequest, landing: ItemLanding, budget: ByteBudget? = nil) {
        self.request = request
        self.landing = landing
        self.budget = budget
    }
}

/// Where the pulling side's sink lands a pull: its owner's choice, which the core hands the sink in `.begin`
/// without reading it.
public enum ItemLanding: Sendable, Equatable {
    /// An INLINE representation's bytes, held in memory and published as `LandedItem.inline`: for content that
    /// must reach no disk, since a file in staging persists until it is reclaimed.
    case memory
    /// Any representation as one entry — an INLINE one as a file of its bytes — in the directory at the
    /// absolute path `directory`, under the name `name` chooses.
    case staged(directory: String, name: ItemLandingName)
    /// Any representation as one entry created at exactly the absolute path `path`, which nothing may have yet,
    /// and written beneath it: nothing beside it is opened or created, so a sink allowed only that one path — a
    /// file promise's destination in a sandboxed app — lands it. It is published as the path's last component.
    case exactPath(String)

    /// Whether this landing takes a representation of `storage`.
    func takes(_ storage: Representation.Storage) -> Bool {
        switch self {
        case .memory: storage == .inline
        case .staged, .exactPath: true
        }
    }
}

/// The name a representation lands under: one path component, as the volume's raw bytes.
public enum ItemLandingName: Sendable, Equatable {
    /// Exactly this name; the publish fails `EEXIST` when anything has it.
    case exactly(Data)
    /// This name, or when anything has it, the first free one in Finder's Keep Both form (`name 2.ext`).
    case keepingBoth(Data)
}

/// What a pull's sink published.
public enum LandedItem: Sendable, Equatable {
    /// An INLINE representation's bytes, landed in memory.
    case inline(Data)
    /// The representation, under this name in its landing's directory.
    case named(Data)
}

/// How one pull this side opened ended.
public enum ItemPullResult: Sendable, Equatable {
    /// The sink published the container, as this.
    case landed(LandedItem)
    /// Nothing landed: the sink refused the container, or could not publish it.
    case failed(WireError)
    /// Nothing landed: the stream closed before the sink verified the container.
    case closed(StreamClosure)
}

/// How one pull this side served ended.
public enum ItemServeResult: Sendable, Equatable {
    /// The puller's `PullOutcome` says its sink published the container.
    case landed
    /// The puller's `PullOutcome` says nothing landed.
    case failed(WireError)
    /// The stream closed without the puller's `PullOutcome`.
    case closed(StreamClosure)
}

/// What the serving side asks of its item source: one container per pull, a read at a time.
public enum ItemSourceEffect: Sendable, Equatable {
    /// Start a container of `representation` of an offer of `FeatureID`'s, held to `request`'s limits.
    case serve(ItemPullID, FeatureID, PullRequest, Representation)
    /// Produce 1 … `maxBytes` more bytes of the container, or report it finished.
    case read(ItemPullID, maxBytes: Int)
    /// The pull ended; drop whatever it holds. The pull's last effect.
    case release(ItemPullID)
}

/// The item source's answer to the outstanding `.read`.
public enum ItemSourceInput: Sendable, Equatable {
    /// The container's next bytes: 1 … `maxBytes` of them.
    case bytes(ItemPullID, Data)
    /// The container has no more bytes.
    case finished(ItemPullID)
    /// The source cannot produce the container: `TOO_LARGE` past the byte ceiling,
    /// `ITEM_REPRESENTATION_UNAVAILABLE`, `READ_FAILED`, …
    case failed(ItemPullID, WireError)
}

/// What the pulling side asks of its item sink, which feeds a container decoder and stages what it
/// decodes. Each pull's sink hears `.begin`, then `.bytes` and at most one `.finish`, and last exactly one
/// of `.commit` and `.abort`: only the core decides that a pull is published.
public enum ItemSinkEffect: Sendable, Equatable {
    /// A container of `representation`, held to the order's request's limits, is coming, to land as its
    /// landing says.
    case begin(ItemPullID, ItemPullOrder, Representation)
    /// The container's next bytes: feed them, then report `.consumed`.
    case bytes(ItemPullID, Data)
    /// Every byte arrived: finish the decoder, then report `.verified` or `.refused`.
    case finish(ItemPullID)
    /// Publish what the pull staged, then report `.published` or `.publishFailed`; a failed publish leaves
    /// nothing. The pull's last effect: nothing withdraws it.
    case commit(ItemPullID)
    /// Drop whatever the pull staged. The pull's last effect.
    case abort(ItemPullID)
}

/// The item sink's reports.
public enum ItemSinkInput: Sendable, Equatable {
    /// It is done with this many delivered bytes.
    case consumed(ItemPullID, Int)
    /// After `.finish`, the decoder finished and the tree is staged.
    case verified(ItemPullID)
    /// It refused the container: `ITEM_CONTAINER_MALFORMED`, `TOO_LARGE`, `ITEM_UNPACK_REFUSED`, …
    case refused(ItemPullID, WireError)
    /// After `.commit`, it published the pull as this.
    case published(ItemPullID, LandedItem)
    /// After `.commit`, it could not publish the pull, and holds nothing of it.
    case publishFailed(ItemPullID, WireError)
}

/// What the item-transfer machine tells its owner.
public enum ItemTransferEvent: Sendable, Equatable {
    /// The far side's offer arrived whole; `ItemCommand.read` decodes each item when asked.
    case offerReceived(ItemSetHeaderValue)
    /// An offer of `FeatureID`'s is no longer valid. Once per offer.
    case offerEnded(FeatureID, ItemOfferOrigin, token: Data, StreamClosure)
    /// A pull this side opened, of an offer of `FeatureID`'s, ended. Once per pull `pull` returned; a committed
    /// pull's follows its sink's publish report, and may follow the connection's `.closed`.
    case pullEnded(FeatureID, ItemPullID, ItemPullResult)
    /// A pull this side served, of an offer of `FeatureID`'s, ended. Once per `.serve`.
    case serveEnded(FeatureID, ItemPullID, ItemServeResult)

    /// The feature of the offer this event is about.
    public var feature: FeatureID {
        switch self {
        case .offerReceived(let header): header.feature
        case .offerEnded(let feature, _, _, _), .pullEnded(let feature, _, _), .serveEnded(let feature, _, _): feature
        }
    }
}

/// One output of the item-transfer machine, in the order it emitted them. An endpoint hands the source
/// and sink effects out as its effects and the events as its events.
package enum ItemTransferOutput: Sendable, Equatable {
    /// For the item source.
    case source(ItemSourceEffect)
    /// For the item sink.
    case sink(ItemSinkEffect)
    /// For the owner.
    case event(ItemTransferEvent)
}

/// One input to the item-transfer machine.
public enum ItemTransferInput: Sendable, Equatable {
    /// The item source's answer.
    case source(ItemSourceInput)
    /// The item sink's report.
    case sink(ItemSinkInput)
}

/// ITEM_TRANSFER on one connection: the offer registry, and the pull server and
/// client over it. A pull is valid only while the offer it names is open, so
/// after every change to the registry the server resets the pulls of offers it
/// no longer holds that it has not sent whole, and the client those it has not
/// committed, before any later input can commit one. Nothing withdraws a commit.
public struct ItemTransfer: FeatureMachine {
    /// ITEM_TRANSFER.
    public static let feature = FeatureID.itemTransfer

    private let availability: Availability<NoParams>
    private let generation: ConnectionGeneration
    package private(set) var offers = ItemOfferRegistry()
    private var server = ItemPullServer()
    private var client = ItemPullClient()
    private var outbox: [ItemTransferOutput] = []
    private var diagnostics: [Diagnostic] = []

    /// A machine for one connection, advertising `availability`.
    public init(availability: Availability<NoParams>, generation: ConnectionGeneration) {
        self.availability = availability
        self.generation = generation
    }

    /// The `ItemTransferCapability` advert, or this build's absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// The machine sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (outputs: [ItemTransferOutput], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// Handles an event on a pull stream.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .opened(let stream, let body):
            server.opened(
                ItemPullID(generation: generation, stream: stream), body: body, offers: offers,
                connection: &connection, outbox: &outbox)
        case .data(let stream, let bytes):
            client.data(stream, bytes, outbox: &outbox)
        case .remoteEnded(let stream, _):
            // A server's pull completes at its close; the connection refuses an early END.
            client.remoteEnded(stream, outbox: &outbox)
        case .writable(let stream):
            server.serve(stream, connection: &connection, outbox: &outbox)
        case .streamClosed(let stream, let closure):
            server.closed(stream, closure, outbox: &outbox)
            client.closed(stream, closure, outbox: &outbox)
        case .sessionEstablished, .usabilityChanged, .policyChanged, .message, .slotFreed, .deadline:
            break
        }
    }

    /// Handles an event on an item-set offer stream, whichever feature's kind it is.
    package mutating func handleOffer(_ event: FeatureEvent, connection: inout Connection) {
        offers.handle(event, connection: &connection, events: &outbox)
        server.offersChanged(offers, connection: &connection)
        client.offersChanged(offers, connection: &connection)
    }

    /// Gives this side's DRAG offer of `token` its drag's `items`; false when it has no whole, empty one.
    mutating func carryLocal(_ token: Data, items: [OfferedItem]) -> Bool {
        offers.carryLocal(token, items: items)
    }

    /// Gives the far side's DRAG offer of `token` its drag's `items`; nil when it did, or why not.
    mutating func carryRemote(_ token: Data, items: [OfferedItem]) -> WireError? {
        offers.carryRemote(token, items: items)
    }

    /// Opens an offer of `offer` on a stream of `kind`, an item-set offer kind this role opens; nil when sent,
    /// or why not.
    public mutating func offer(_ offer: ItemOffer, kind: StreamKind, connection: inout Connection) -> WireError? {
        offers.offer(offer, kind: kind, connection: &connection)
    }

    /// Withdraws this side's offer of `token`, resetting it with `code`.
    public mutating func withdraw(_ token: Data, code: ErrorCode = .cancelled, connection: inout Connection) {
        offers.withdraw(token, code: code, connection: &connection)
    }

    /// Releases the far side's offer of `token`: this side pulls nothing more of it. Once the offer is whole
    /// the release is END with `endBody`, its kind's acceptor END body.
    public mutating func release(_ token: Data, endBody: Data = Data(), connection: inout Connection) {
        offers.release(token, endBody: endBody, connection: &connection)
    }

    /// Refuses the far side's offer of `token` with `error`: this side pulls nothing of it, and says why.
    public mutating func refuse(_ token: Data, _ error: WireError, connection: inout Connection) {
        offers.refuse(token, error, connection: &connection)
    }

    /// Pulls one representation of the far side's open offer, as `order` says.
    public mutating func pull(_ order: ItemPullOrder, connection: inout Connection) -> Result<ItemPullID, WireError> {
        client.pull(order, offers: offers, generation: generation, connection: &connection, outbox: &outbox)
    }

    /// Whether a pull this side committed has not had its sink's publish report: its `.pullEnded` is still
    /// owed, though its connection may have finished.
    public var hasLandingsInFlight: Bool { client.hasLandingsInFlight }

    /// Cancels a pull this side opened.
    public mutating func cancel(_ id: ItemPullID, connection: inout Connection) {
        guard id.generation == generation else { return }
        client.cancel(id.stream, connection: &connection)
    }

    /// Handles the source's answer or the sink's report.
    public mutating func handle(input: ItemTransferInput, connection: inout Connection, now: CoreInstant) {
        switch input {
        case .source(let input):
            server.handle(
                input, generation: generation, connection: &connection, outbox: &outbox, diagnostics: &diagnostics)
        case .sink(let input):
            client.handle(
                input, generation: generation, connection: &connection, outbox: &outbox, diagnostics: &diagnostics)
        }
    }
}
