#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

/// An item set as an offer stream carries it.
public struct ItemOffer: Sendable, Equatable {
    /// The 16 bytes naming the offer, which a pull quotes.
    public var token: Data
    /// The receiver keeps the content out of history and logs.
    public var concealed: Bool
    /// The receiver keeps the content out of history.
    public var transient: Bool
    /// The items, in the order they are sent.
    public var items: [OfferedItem]

    /// Creates an offer.
    public init(token: Data, concealed: Bool = false, transient: Bool = false, items: [OfferedItem]) {
        self.token = token
        self.concealed = concealed
        self.transient = transient
        self.items = items
    }
}

/// An item-set offer's header: what the far side's OPEN announced.
public struct ItemSetHeaderValue: Sendable, Equatable {
    /// The 16 bytes naming the offer, which a pull quotes.
    public var token: Data
    /// The receiver keeps the content out of history and logs.
    public var concealed: Bool
    /// The receiver keeps the content out of history.
    public var transient: Bool
    /// The items the offer sends.
    public var count: Int

    init(_ header: Kernova_V2_ItemSetHeader) {
        token = header.token
        concealed = header.concealed
        transient = header.transient
        count = Int(header.count)
    }
}

/// Whose offer an event is about: this side's or the far side's. Their tokens are separate namespaces.
public enum ItemOfferOrigin: Sendable, Equatable {
    /// This side offered it.
    case local
    /// The far side offered it.
    case remote
}

/// How one pull ended, on either side.
public enum ItemPullResult: Sendable, Equatable {
    /// The container landed: on the pulling side, the sink verified it and was told to commit; on the
    /// serving side, the puller's `PullOutcome` says so.
    case landed
    /// Nothing landed: the sink refused the container, or the puller's `PullOutcome` says so.
    case failed(WireError)
    /// Nothing landed: the stream closed before the sink verified the container.
    case closed(StreamClosure)
}

/// What the serving side asks of its item source: one container per pull, a read at a time.
public enum ItemSourceEffect: Sendable, Equatable {
    /// Start a container of `representation`, held to `request`'s limits.
    case serve(ItemPullID, PullRequest, Representation)
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
/// of `.commit` and `.abort`: only the core decides that a pull landed.
public enum ItemSinkEffect: Sendable, Equatable {
    /// A container of `representation`, held to `request`'s limits, is coming.
    case begin(ItemPullID, PullRequest, Representation)
    /// The container's next bytes: feed them, then report `.consumed`.
    case bytes(ItemPullID, Data)
    /// Every byte arrived: finish the decoder, then report `.verified` or `.refused`.
    case finish(ItemPullID)
    /// Land what the pull staged. The pull's last effect.
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
}

/// What the item-transfer machine tells its owner.
public enum ItemTransferEvent: Sendable, Equatable {
    /// The far side's offer arrived whole; `ItemTransfer.remoteItem` decodes each item when asked.
    case offerReceived(ItemSetHeaderValue)
    /// An offer is no longer valid. Once per offer.
    case offerEnded(ItemOfferOrigin, token: Data, StreamClosure)
    /// A pull this side opened ended. Once per pull `pull` returned.
    case pullEnded(ItemPullID, ItemPullResult)
    /// A pull this side served ended. Once per `.serve`.
    case serveEnded(ItemPullID, ItemPullResult)
}

/// One output of the item-transfer machine.
public enum ItemTransferOutput: Sendable, Equatable {
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
/// after every change to the registry both the server and the client reset the
/// pulls of offers it no longer holds, before any later input can commit one.
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

    /// Handles an event on an offer stream, whichever feature's kind it is.
    package mutating func handleOffer(_ event: FeatureEvent, connection: inout Connection) {
        offers.handle(event, connection: &connection, events: &outbox)
        server.offersChanged(offers, connection: &connection)
        client.offersChanged(offers, connection: &connection)
    }

    /// Item `index` of the far side's open offer of `token`, decoded now; nil when none is held.
    public func remoteItem(token: Data, index: Int) -> OfferedItem? {
        offers.remoteItem(token, index)
    }

    /// Opens an offer of `offer` on a stream of `kind`; nil when sent, or why not.
    package mutating func offer(_ offer: ItemOffer, kind: StreamKind, connection: inout Connection) -> WireError? {
        offers.offer(offer, kind: kind, connection: &connection)
    }

    /// Withdraws this side's offer of `token`.
    package mutating func withdraw(_ token: Data, connection: inout Connection) {
        offers.withdraw(token, connection: &connection)
    }

    /// Releases the far side's offer of `token`: this side pulls nothing more of it.
    package mutating func release(_ token: Data, connection: inout Connection) {
        offers.release(token, connection: &connection)
    }

    /// Pulls one representation of the far side's open offer.
    public mutating func pull(_ request: PullRequest, connection: inout Connection) -> Result<ItemPullID, WireError> {
        client.pull(request, offers: offers, generation: generation, connection: &connection, outbox: &outbox)
    }

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
