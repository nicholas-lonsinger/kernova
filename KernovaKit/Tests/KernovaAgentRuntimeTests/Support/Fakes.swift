#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaSynchronization
import KernovaWire
import Testing

/// Holds each dial until the test answers it.
final class ScriptedDialer: TransportDialer {
    private let pending = Locked<[@Sendable (Result<any ByteStream, DialFailure>) -> Void]>([])
    /// One element per dial, numbered from 1.
    let dials = Recorder<Int>()

    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        let count = pending.withLock { pending in
            pending.append(completion)
            return pending.count
        }
        dials.record(count)
    }

    /// Answers dial `number`, counted from 1.
    func answer(_ number: Int, _ result: Result<any ByteStream, DialFailure>) {
        let completion = pending.withLock { $0[number - 1] }
        completion(result)
    }
}

/// Item adapters that are only registered: a test that offers nothing never reaches them.
struct RegisteredItemAdapters: ItemSource, ItemSink {
    /// The adapters, serving `features`.
    static func adapters(_ features: Set<FeatureID> = []) -> ItemAdapters {
        ItemAdapters(source: RegisteredItemAdapters(), sink: RegisteredItemAdapters(), features: features)
    }

    func handle(_ effect: ItemSourceEffect, reporter: ItemSourceReporter) {
        Issue.record("the source was asked \(effect)")
    }

    func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter) {
        Issue.record("the sink was asked \(effect)")
    }
}

/// Serves `SimItems` containers from memory, and lands a pull by taking its bytes. With `holdsReads`, it never
/// answers a read, so a pull it serves stays open until cancelled.
final class MemoryItems: ItemSource, ItemSink {
    private let source = Locked(ContainerItemSource())
    let holdsReads: Bool
    /// Every effect the sink was asked to carry out.
    let sinkEffects = Recorder<ItemSinkEffect>()

    init(holdsReads: Bool = false) {
        self.holdsReads = holdsReads
    }

    /// These adapters, serving `features`.
    func adapters(_ features: Set<FeatureID> = ItemFeatureAvailability.offering) -> ItemAdapters {
        ItemAdapters(source: self, sink: self, features: features)
    }

    func handle(_ effect: ItemSourceEffect, reporter: ItemSourceReporter) {
        if let input = serve(effect) { reporter.report(input) }
    }

    func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter) {
        if let input = land(effect) { reporter.report(input) }
    }

    /// The source's answer to `effect`, if it takes one now.
    func serve(_ effect: ItemSourceEffect) -> ItemSourceInput? {
        if holdsReads, case .read = effect { return nil }
        return source.withLock { $0.handle(effect) }
    }

    /// The sink's report on `effect`, if it takes one.
    func land(_ effect: ItemSinkEffect) -> ItemSinkInput? {
        sinkEffects.record(effect)
        switch effect {
        case .bytes(let id, let bytes): return .consumed(id, bytes.count)
        case .finish(let id): return .verified(id)
        case .commit(let id): return .published(id, .named(Data()))
        case .begin, .abort: return nil
        }
    }
}

/// Accepts every action it offers and hands off at once, unless told to hold before or after accepting.
/// It can never confirm a cancel, so a cancel ends the request `.unconfirmed`.
final class FakePowerAdapter: PowerAdapter {
    private let reporter = Locked<PowerReporter?>(nil)
    let performed = Recorder<PowerRequestID>()
    /// The requests performed without waiting for apps.
    let performedIgnoringApps = Recorder<PowerRequestID>()
    let cancelled = Recorder<PowerRequestID>()
    let accepts: Bool
    let handsOff: Bool
    let initial: Availability<PowerOffer>

    init(
        accepts: Bool = true, handsOff: Bool = true,
        initial: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown]))
    ) {
        self.accepts = accepts
        self.handsOff = handsOff
        self.initial = initial
    }

    func start(reporter: PowerReporter) {
        self.reporter.withLock { $0 = reporter }
        reporter.report(.availability(initial))
    }

    func perform(_ id: PowerRequestID, _ action: PowerAction, ignoringApps: Bool) {
        performed.record(id)
        if ignoringApps { performedIgnoringApps.record(id) }
        guard accepts else { return }
        let reporter = reporter.withLock { $0 }
        reporter?.report(.accepted(id))
        if handsOff { reporter?.report(.handedOff(id)) }
    }

    func cancel(_ id: PowerRequestID) {
        cancelled.record(id)
        report(.unconfirmed(id))
    }

    /// Reports `input` as the adapter would, from the test's thread.
    func report(_ input: PowerInput) {
        reporter.withLock { $0 }?.report(input)
    }
}

/// Serves `content` by position.
final class FakePayloadSource: UpdatePayloadSource {
    let content: Data

    init(content: Data) {
        self.content = content
    }

    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        let start = Int(clamping: min(offset, UInt64(content.count)))
        completion(.success(Data(content[start..<min(content.count, start + count)])))
    }

    /// A deterministic payload of `count` bytes: a block of prime length repeated, so no two frames at
    /// different offsets carry the same bytes.
    static func payload(_ count: Int) -> Data {
        let block = Data((0..<4_093).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) })
        var payload = Data(capacity: count + block.count)
        while payload.count < count { payload.append(block) }
        return payload.prefix(count)
    }
}
