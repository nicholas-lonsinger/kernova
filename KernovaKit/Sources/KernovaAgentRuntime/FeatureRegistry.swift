#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import KernovaLogging
import KernovaSynchronization

/// The adapters a platform shell registers. A feature without one is advertised absent `NOT_IMPLEMENTED`.
public struct PeerFeatureRegistry: Sendable {
    /// Performs power actions.
    public var power: (any PowerAdapter)?
    /// The process's log ring and its sink.
    public var logs: LogForwarding?
    /// Installs update payloads.
    public var update: (any UpdateInstaller)?
    /// Serves and lands items.
    public var items: ItemAdapters?

    /// Creates a registry.
    public init(
        power: (any PowerAdapter)? = nil, logs: LogForwarding? = nil, update: (any UpdateInstaller)? = nil,
        items: ItemAdapters? = nil
    ) {
        self.power = power
        self.logs = logs
        self.update = update
        self.items = items
    }
}

/// The adapters that move items' bytes, and the features that offer items over them: the source serves this
/// side's offers, the sink lands the far side's. Without them, or with no feature over them, item transfer is
/// advertised absent `NOT_IMPLEMENTED`, and so is every feature that offers items.
public struct ItemAdapters: Sendable {
    /// Serves this side's offers.
    public var source: any ItemSource
    /// Lands the far side's offers.
    public var sink: any ItemSink
    /// The features this side's owner handles, each one of `ItemFeatureAvailability.offering`: each is
    /// advertised available where listed, and absent `NOT_IMPLEMENTED` otherwise.
    public let features: Set<FeatureID>

    /// Creates the adapters, serving `features`.
    public init(source: any ItemSource, sink: any ItemSink, features: Set<FeatureID> = []) {
        assert(
            features.isSubset(of: ItemFeatureAvailability.offering),
            "\(features.subtracting(ItemFeatureAvailability.offering)) offer no items")
        self.source = source
        self.sink = sink
        self.features = features
    }

    /// What a connection these adapters, or none, serve advertises of item transfer and the features over it.
    static func availability(_ adapters: ItemAdapters?) -> ItemFeatureAvailability {
        guard let adapters, !adapters.features.isEmpty else {
            var none = ItemFeatureAvailability.notImplemented
            none.itemTransfer = .absent(
                .notImplemented, debugDetail: adapters == nil ? "no adapter registered" : "no feature offers items")
            return none
        }
        var availability = ItemFeatureAvailability.notImplemented
        availability.itemTransfer = .available(NoParams())
        for feature in ItemFeatureAvailability.offering {
            availability[offering: feature] =
                adapters.features.contains(feature)
                ? .available(NoParams()) : .absent(.notImplemented, debugDetail: "no owner registered")
        }
        return availability
    }
}

/// Serves this side's offered items, one container per pull, as `ItemSourceEffect` specifies. It returns at
/// once; anything that waits runs on its own queue, thread or actor.
public protocol ItemSource: Sendable {
    /// Carries out `effect`, answering a `.read` through `reporter`, which reaches the connection that asked.
    func handle(_ effect: ItemSourceEffect, reporter: ItemSourceReporter)
}

/// Lands the far side's items, one container per pull, as `ItemSinkEffect` specifies. It returns at once;
/// anything that waits runs on its own queue, thread or actor.
public protocol ItemSink: Sendable {
    /// Carries out `effect`, reporting through `reporter`, which reaches the connection that asked.
    func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter)
}

/// The connection an item adapter's effect came from. No two connections in the process share one, though
/// connections of different runtimes share generations, so `ItemPullID`s.
package struct ItemConnection: Hashable, Sendable {
    private static let drawn = Locked<UInt64>(0)

    /// This side's role on the connection, which decides which way the containers it serves travel.
    package let role: PeerRole
    private let key: UInt64

    /// A connection no other in the process is, on which this side has `role`.
    package init(role: PeerRole) {
        self.role = role
        key = Self.drawn.withLock { count in
            count += 1
            return count
        }
    }
}

/// How an item source answers one connection, from any thread.
public struct ItemSourceReporter: Sendable {
    /// The connection whose effect this reporter came with.
    package let connection: ItemConnection
    let deliver: @Sendable (ItemSourceInput) -> Void

    package init(_ connection: ItemConnection, _ deliver: @escaping @Sendable (ItemSourceInput) -> Void) {
        self.connection = connection
        self.deliver = deliver
    }

    /// Reports `input` to the connection whose effect this reporter came with.
    public func report(_ input: ItemSourceInput) {
        deliver(input)
    }
}

/// How an item sink reports to one connection, from any thread.
public struct ItemSinkReporter: Sendable {
    /// The connection whose effect this reporter came with.
    package let connection: ItemConnection
    let deliver: @Sendable (ItemSinkInput) -> Void

    package init(_ connection: ItemConnection, _ deliver: @escaping @Sendable (ItemSinkInput) -> Void) {
        self.connection = connection
        self.deliver = deliver
    }

    /// Reports `input` to the connection whose effect this reporter came with.
    public func report(_ input: ItemSinkInput) {
        deliver(input)
    }
}

/// Performs a peer's power actions. Every method returns at once; anything that waits runs on the
/// adapter's own queue, thread or actor.
public protocol PowerAdapter: Sendable {
    /// Called once, before the first connection. Reports `.availability` at once and on every change.
    func start(reporter: PowerReporter)
    /// Ends in exactly one terminal report — `.refused`, `.cancelled`, `.unconfirmed`, `.handedOff`,
    /// `.blocked`, `.cancelledInGuest` or `.failed` — after `.accepted` and the stages it reaches, if any.
    /// Until then the process performs no other request. `ignoringApps` asks for `action` without waiting for
    /// apps, and comes only for an action the adapter's offer lists among `ignoringApps`.
    func perform(_ id: PowerRequestID, _ action: PowerAction, ignoringApps: Bool)
    /// Reports `.cancelled` when the OS confirms the request did not start, `.accepted` when the OS took
    /// it first, and `.unconfirmed` when it cannot tell.
    func cancel(_ id: PowerRequestID)
}

/// Installs a peer's update payloads. Every method returns at once.
public protocol UpdateInstaller: Sendable {
    /// Called once, before the first connection. Reports `.availability` (formats, rejected hash) at once
    /// and on every change.
    func start(reporter: UpdateReporter)
    /// Persists `hash` as the install's rejected hash, in its slot metadata.
    func recordRejected(_ hash: Data)
    /// Clears the install's rejected hash.
    func clearRejected()
    /// Writes the pull's next bytes; reports `.consumed(id, n)` once written.
    func write(_ id: UpdatePullID, _ bytes: Data)
    /// Verifies the hash and installs; reports `.installed` or `.rejected`.
    func complete(_ id: UpdatePullID, _ manifest: UpdateManifestValue)
    /// Drops whatever the pull wrote.
    func abort(_ id: UpdatePullID)
}

/// Serves the host's update payloads.
public protocol UpdatePayloadSource: Sendable {
    /// Reads 1 … `count` bytes of `manifest`'s payload from `offset`, as `pread` does, and calls
    /// `completion` on any thread. It keeps no state between reads: the endpoint asks for each read's
    /// position and never past the manifest's size, so a read that returns no bytes fails the pull with
    /// `READ_FAILED`.
    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void)
}

/// How a power adapter reports, from any thread.
public struct PowerReporter: Sendable {
    let deliver: @Sendable (PowerInput) -> Void

    /// A reporter handing each report to `deliver`.
    package init(deliver: @escaping @Sendable (PowerInput) -> Void) {
        self.deliver = deliver
    }

    /// Reports `input` to the current connection's endpoint, and its availability to later ones.
    public func report(_ input: PowerInput) {
        deliver(input)
    }
}

/// How an update installer reports, from any thread.
public struct UpdateReporter: Sendable {
    let deliver: @Sendable (UpdateInput) -> Void

    /// Reports `input` to the current connection's endpoint, and its availability to later ones.
    public func report(_ input: UpdateInput) {
        deliver(input)
    }
}

/// The peer's process-wide log ring and the sink that fills it. The ring outlives every connection; only
/// the runtime sets its mode and takes batches from it, inside driver turns.
public final class LogForwarding: Sendable {
    /// The records between the logger and the wire.
    let ring = Locked(LogRing())
    /// Posts `.logs(.recordsAvailable)` to the current connection; never calls a driver synchronously.
    let recordsAvailable = Locked<(@Sendable () -> Void)?>(nil)

    /// An empty ring, buffering.
    public init() {}

    /// Whether the ring forwards its records: the host's policy last enabled LOGS. The mode outlives the
    /// connection that set it.
    public var isForwarding: Bool {
        ring.withLock { $0.mode == .forwarding }
    }

    /// The sink to install with `KernovaLogger.bootstrapProcessSink(_:)`.
    public var sink: KernovaLogger.ForwardingSink {
        { [self] level, subsystem, category, segments in
            append(
                LogRecordValue(
                    timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), level: LogLevelValue(level),
                    subsystem: subsystem, category: category,
                    segments: segments.map { LogSegmentValue(text: $0.text, isPrivate: $0.isPrivate) }))
        }
    }

    /// Appends `record`, waking the forwarder when the ring was empty.
    public func append(_ record: LogRecordValue) {
        guard ring.withLock({ $0.append(record) }) else { return }
        recordsAvailable.withLock { $0 }?()
    }
}

extension LogLevelValue {
    init(_ level: KernovaLogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .warning: self = .warning
        case .error: self = .error
        case .fault: self = .fault
        }
    }
}
