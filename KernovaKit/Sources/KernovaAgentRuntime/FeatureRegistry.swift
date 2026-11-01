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

    /// Creates a registry.
    public init(
        power: (any PowerAdapter)? = nil, logs: LogForwarding? = nil, update: (any UpdateInstaller)? = nil
    ) {
        self.power = power
        self.logs = logs
        self.update = update
    }
}

/// Performs a peer's power actions. Every method returns at once; anything that waits runs on the
/// adapter's own queue, thread or actor.
public protocol PowerAdapter: Sendable {
    /// Called once, before the first connection. Reports `.availability` at once and on every change.
    func start(reporter: PowerReporter)
    /// Ends in exactly one terminal report — `.refused`, `.cancelled`, `.unconfirmed`, `.handedOff`,
    /// `.blocked`, `.cancelledInGuest` or `.failed` — after `.accepted` and the stages it reaches, if any.
    /// Until then the process performs no other request. With `skippingBlockers` the OS does not wait for
    /// the apps that block `action`; the request is one the adapter's offer lists in that mode.
    func perform(_ id: PowerRequestID, _ action: PowerAction, skippingBlockers: Bool)
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
