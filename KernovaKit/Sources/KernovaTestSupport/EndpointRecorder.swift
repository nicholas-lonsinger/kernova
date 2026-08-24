import Foundation
import KernovaKit

/// Records everything one ``ClipboardEndpoint`` reports to its owner, so a test
/// asserts on the surface an adapter would render rather than on private state.
@MainActor
public final class EndpointRecorder: ClipboardEndpointDelegate {
    /// One `didRetractOffer` call.
    public struct Retraction: Sendable {
        /// The generation retired, or `nil` when this side held none.
        public let generation: UInt64?
        /// Why it stopped being servable.
        public let reason: ClipboardEndpoint.RetractReason
    }

    /// One `didRefuse` call.
    public struct Refusal: Sendable {
        /// The gesture that was refused.
        public let gesture: ClipboardTransferGesture
        /// What refused it.
        public let failure: ClipboardTransferFailure
    }

    /// Every offer the peer made, in arrival order.
    public private(set) var offers: [ClipboardEndpoint.InboundOffer] = []

    /// Every retraction, in order.
    public private(set) var retractions: [Retraction] = []

    /// Every refusal, in order.
    public private(set) var refusals: [Refusal] = []

    /// Every activity, in order.
    public private(set) var activities: [ClipboardEndpoint.Activity] = []

    /// How many times the channel ended under the endpoint.
    public private(set) var endedCount = 0

    /// Fires after every recorded call.
    public let changed = AsyncGate()

    /// Creates a recorder holding nothing.
    public init() {}

    /// How many times `activity` was recorded.
    public func activityCount(_ activity: ClipboardEndpoint.Activity) -> Int {
        activities.filter { $0 == activity }.count
    }

    // MARK: - Waiting

    /// Suspends until at least `count` offers have arrived, returning the last.
    @discardableResult
    public func waitForOffer(count: Int = 1) async throws -> ClipboardEndpoint.InboundOffer {
        try await changed.wait { self.offers.count >= count }
        guard let offer = offers.last else { throw TestFailure("No offer recorded") }
        return offer
    }

    /// Suspends until at least `count` retractions have arrived, returning the
    /// last.
    @discardableResult
    public func waitForRetraction(count: Int = 1) async throws -> Retraction {
        try await changed.wait { self.retractions.count >= count }
        guard let retraction = retractions.last else {
            throw TestFailure("No retraction recorded")
        }
        return retraction
    }

    /// Suspends until a refusal matching `predicate` has been recorded, and
    /// returns the first one that does.
    @discardableResult
    public func waitForRefusal(
        where predicate: @escaping @MainActor (Refusal) -> Bool = { _ in true }
    ) async throws -> Refusal {
        try await changed.wait { self.refusals.contains(where: predicate) }
        guard let refusal = refusals.first(where: predicate) else {
            throw TestFailure("Matching refusal vanished from the recorder")
        }
        return refusal
    }

    /// Suspends until `activity` has been recorded at least `count` times.
    public func waitForActivity(
        _ activity: ClipboardEndpoint.Activity, count: Int = 1
    ) async throws {
        try await changed.wait { self.activityCount(activity) >= count }
    }

    /// Suspends until the channel has ended under the endpoint.
    public func waitForEnd() async throws {
        try await changed.wait { self.endedCount > 0 }
    }

    /// Observes for `duration` and throws when any refusal arrived past
    /// `sinceCount`.
    ///
    /// A negative assertion has no signal to await, so it takes a fixed
    /// observation window rather than a wait timeout (docs/TESTING.md).
    public func expectNoNewRefusals(
        sinceCount before: Int, for duration: TimeInterval = 0.15
    ) async throws {
        try await MonotonicEngineClock().sleep(for: duration)
        guard refusals.count == before else {
            let extras = Array(refusals[min(before, refusals.count)...])
            throw TestFailure(
                "Expected no new refusals over \(duration) s; got \(extras.count): "
                    + extras.map { "\($0.gesture)/\($0.failure)" }.joined(separator: ", "))
        }
    }

    // MARK: - ClipboardEndpointDelegate

    /// Records an offer the peer made.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer
    ) {
        offers.append(offer)
        changed.notify()
    }

    /// Records an offer that stopped being servable.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason
    ) {
        retractions.append(Retraction(generation: generation, reason: reason))
        changed.notify()
    }

    /// Records a refused gesture.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRefuse gesture: ClipboardTransferGesture,
        failure: ClipboardTransferFailure
    ) {
        refusals.append(Refusal(gesture: gesture, failure: failure))
        changed.notify()
    }

    /// Records something a status surface may want to render.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRecord activity: ClipboardEndpoint.Activity
    ) {
        activities.append(activity)
        changed.notify()
    }

    /// Records the channel closing under the endpoint.
    public func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        endedCount += 1
        changed.notify()
    }
}
