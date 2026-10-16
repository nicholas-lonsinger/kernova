import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The `kernova:` link front door: which verb a link runs, what it waits for
/// before running one, and where a refusal lands when nobody is waiting for it.
@Suite("Kernova link gateway", .caseScoped)
@MainActor
struct VMURLGatewayTests {
    /// What the gateway did, in the order it did it.
    private enum Step: Equatable {
        case prepared
        case summoned
        case presented(CommandError)
    }

    /// A readiness await the test holds open, so a verb's wait for the first
    /// library read is observable rather than instantaneous.
    private final class ReadinessGate: @unchecked Sendable {
        /// Fires when the gateway starts waiting, and again when it is let go.
        private let gate = AsyncGate()
        private let lock = NSLock()
        private var waiting = false
        private var isOpen = false

        /// Whether the gateway is parked on the readiness await.
        var isWaiting: Bool { lock.withLock { waiting } }

        /// Suspends until ``open()``, as the app's first library read does.
        func wait() async {
            lock.withLock { waiting = true }
            gate.notify()
            try? await gate.wait { self.lock.withLock { self.isOpen } }
        }

        /// Lands the library read.
        func open() {
            lock.withLock { isOpen = true }
            gate.notify()
        }

        /// Suspends until the gateway is parked on the await.
        func awaitWaiting() async throws {
            try await gate.wait { self.isWaiting }
        }
    }

    /// Records everything the gateway asked of the app, in order.
    @MainActor
    private final class Trace {
        private(set) var steps: [Step] = []

        func record(_ step: Step) { steps.append(step) }

        var presented: [CommandError] {
            steps.compactMap { if case .presented(let error) = $0 { error } else { nil } }
        }
    }

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// A gateway over `wired`'s core, whose library read has already landed
    /// unless `awaitReady` holds it.
    private func makeGateway(
        _ wired: WiredCommandCore,
        trace: Trace,
        awaitReady: @escaping @Sendable () async -> Void = {}
    ) -> VMURLGateway {
        VMURLGateway(
            commands: wired.core,
            readiness: LibraryReadiness(awaitReady: awaitReady),
            prepareToSurface: { trace.record(.prepared) },
            summonLibrary: { trace.record(.summoned) },
            present: { trace.record(.presented($0)) })
    }

    /// A VM with a display to put in front of the user, which the open verb
    /// accepts.
    @discardableResult
    private func registerRunning(in wired: WiredCommandCore, name: String = "Sonoma") -> VMInstance {
        wired.register(name: name, phase: .running(sessionID: UUID()))
    }

    // MARK: - Routes

    @Test("An open link runs the open verb on the VM it names")
    func openLinkRunsTheOpenVerb() async throws {
        let wired = WiredCommandCore()
        let sonoma = registerRunning(in: wired)
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(wired.surfacedDisplays == [sonoma.id])
        #expect(wired.revealedInLibrary.isEmpty)
        // The verb opens exactly the surface the link asked for; a library
        // window behind it is one nobody asked for.
        #expect(trace.steps == [.prepared])
    }

    /// A stopped VM tells the two verbs apart: open refuses it, and reveal
    /// lands on its library row.
    @Test("A reveal link runs the reveal verb on the VM it names")
    func revealLinkRunsTheRevealVerb() async throws {
        let wired = WiredCommandCore()
        let sonoma = wired.register(name: "Sonoma")
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://reveal/Sonoma"))

        #expect(wired.revealedInLibrary == [sonoma.id])
        #expect(wired.surfacedDisplays.isEmpty)
        #expect(trace.presented.isEmpty)
    }

    /// Readied once, for the alert: the refused verb itself surfaced nothing.
    @Test("A verb refusal readies the app once and summons the library before it is shown")
    func aVerbRefusalSummonsTheLibraryBeforePresenting() async throws {
        let wired = WiredCommandCore()
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(
            trace.steps == [.prepared, .summoned, .presented(.notFound(.idOrName("Sonoma")))])
    }

    @Test("The verb waits for the app's first library read")
    func theVerbWaitsForTheFirstLibraryRead() async throws {
        let wired = WiredCommandCore()
        let sonoma = registerRunning(in: wired)
        let trace = Trace()
        let readiness = ReadinessGate()
        let gateway = makeGateway(
            wired, trace: trace, awaitReady: { await readiness.wait() })

        let link = try url("kernova://open/Sonoma")
        let handled = Task { await gateway.handle(link) }
        try await readiness.awaitWaiting()
        #expect(wired.surfacedDisplays.isEmpty)
        #expect(trace.steps.isEmpty)

        readiness.open()
        await handled.value
        #expect(wired.surfacedDisplays == [sonoma.id])
    }

    // MARK: - Refusals the core raises

    @Test("A name several VMs answer to is shown in the app")
    func anAmbiguousNameIsShownInTheApp() async throws {
        let wired = WiredCommandCore()
        let first = registerRunning(in: wired)
        let second = registerRunning(in: wired)
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://open/Sonoma"))

        let presented = try #require(trace.presented.first)
        #expect(trace.presented.count == 1)
        guard case .ambiguous(let selector, let candidates) = presented else {
            Issue.record("expected an ambiguity refusal, got \(presented)")
            return
        }
        #expect(selector == .idOrName("Sonoma"))
        #expect(Set(candidates.map(\.id)) == [first.id, second.id])
        #expect(wired.surfacedDisplays.isEmpty)
    }

    @Test("A name no VM answers to is shown in the app")
    func aNameNoVMAnswersToIsShownInTheApp() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Sonoma")
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://reveal/Ghost"))

        #expect(trace.presented == [.notFound(.idOrName("Ghost"))])
        #expect(wired.revealedInLibrary.isEmpty)
    }

    @Test("A VM whose state admits no open refuses the open route, in the app")
    func aStoppedVMRefusesTheOpenRoute() async throws {
        let wired = WiredCommandCore()
        let sonoma = wired.register(name: "Sonoma")
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://open/Sonoma"))

        let presented = try #require(trace.presented.first)
        #expect(trace.presented.count == 1)
        guard case .invalidState(let vm, let current, let allowed, _) = presented else {
            Issue.record("expected an invalid-state refusal, got \(presented)")
            return
        }
        #expect(vm.id == sonoma.id)
        #expect(current == .stopped)
        #expect(!allowed.contains(.open))
        #expect(wired.surfacedDisplays.isEmpty)
    }

    // MARK: - Refusals the link itself earns

    @Test("A route Kernova does not offer is refused without running any verb")
    func anUnknownRouteIsRefusedWithoutCallingAnyVerb() async throws {
        let wired = WiredCommandCore()
        let sonoma = wired.register(name: "Sonoma")
        let trace = Trace()
        await makeGateway(wired, trace: trace).handle(try url("kernova://start/Sonoma"))

        #expect(wired.surfacedDisplays.isEmpty)
        #expect(wired.revealedInLibrary.isEmpty)
        #expect(sonoma.status == .stopped)
        #expect(
            trace.steps == [
                .prepared, .summoned,
                .presented(.invalidArgument(VMURLRoute.Refusal.unknownRoute("start").message)),
            ])
    }

    @Test("A link Kernova cannot read is refused without waiting for the library read")
    func aMalformedLinkIsRefusedWithoutWaitingForTheLibrary() async throws {
        let wired = WiredCommandCore()
        let trace = Trace()
        let readiness = ReadinessGate()
        let gateway = makeGateway(
            wired, trace: trace, awaitReady: { await readiness.wait() })

        // Nothing about the library decides this refusal, so it never parks on
        // a read that a launch may still have in flight.
        await gateway.handle(try url("kernova://start/Sonoma"))

        #expect(!readiness.isWaiting)
        #expect(trace.presented.count == 1)
    }
}
