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

    /// One `didReceiveDragHandOff` call.
    public struct HandOff: Equatable, Sendable {
        /// The drag being handed over.
        public let generation: UInt64
        /// The step the guest reported.
        public let step: ClipboardDragHandOffStep
    }

    /// One `didReceiveDragCatcher` call.
    public struct CatcherChange: Equatable, Sendable {
        /// The drag whose catcher it names.
        public let generation: UInt64
        /// Whether the catcher is to be shown again, or stood down.
        public let shown: Bool

        /// One call's arguments.
        public init(generation: UInt64, shown: Bool) {
            self.generation = generation
            self.shown = shown
        }
    }

    /// Every offer the peer made, in arrival order.
    public private(set) var offers: [ClipboardEndpoint.InboundOffer] = []

    /// Every drag the guest offered, in arrival order.
    public private(set) var drags: [ClipboardInboundDrag] = []

    /// Every generation the host asked to take, in arrival order.
    public private(set) var takes: [UInt64] = []

    /// Every hand-off step the guest reported, in arrival order.
    public private(set) var handOffs: [HandOff] = []

    /// Every `DragCatcher` the host sent, in arrival order.
    public private(set) var catcherChanges: [CatcherChange] = []

    /// Every generation the host said it is done with, in arrival order.
    public private(set) var completedDrags: [UInt64] = []

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

    /// Suspends until at least `count` drags have arrived, returning the last.
    @discardableResult
    public func waitForDrag(count: Int = 1) async throws -> ClipboardInboundDrag {
        try await changed.wait { self.drags.count >= count }
        guard let drag = drags.last else { throw TestFailure("No drag recorded") }
        return drag
    }

    /// Suspends until `predicate` holds over what has been recorded.
    public func wait(until predicate: () -> Bool) async throws {
        try await changed.wait(until: predicate)
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

    /// Drains the main queue and throws when any refusal arrived past
    /// `sinceCount`.
    ///
    /// The endpoint raises a refusal on the main actor or queues it there from
    /// the thread that settles the gesture, so the drain closes the window for
    /// every refusal raised before this call — valid only after the test has
    /// awaited the step that would raise the forbidden one: the fire or pull
    /// returning, or the synchronous call under test.
    public func expectNoNewRefusals(sinceCount before: Int) async throws {
        await drainMainQueue()
        guard refusals.count == before else {
            let extras = Array(refusals[min(before, refusals.count)...])
            throw TestFailure(
                "Expected no new refusals; got \(extras.count): "
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

    /// Records a drag the guest offered.
    public func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDrag drag: ClipboardInboundDrag) {
        drags.append(drag)
        changed.notify()
    }

    /// Records the host asking to take a drag.
    public func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDragTake generation: UInt64) {
        takes.append(generation)
        changed.notify()
    }

    /// Records the host standing a catcher down or showing it again.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveDragCatcher shown: Bool, generation: UInt64
    ) {
        catcherChanges.append(CatcherChange(generation: generation, shown: shown))
        changed.notify()
    }

    /// Records one hand-off step.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveDragHandOff step: ClipboardDragHandOffStep,
        generation: UInt64
    ) {
        handOffs.append(HandOff(generation: generation, step: step))
        changed.notify()
    }

    /// Records the host being done with a drag.
    public func endpoint(_ endpoint: ClipboardEndpoint, didCompleteDrag generation: UInt64) {
        completedDrags.append(generation)
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
