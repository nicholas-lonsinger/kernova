import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The `kernova:` link front door: which verb a link runs, what it waits for
/// before running one, and where a refusal lands when nobody is waiting for it.
@Suite("Kernova link gateway", .admissionGated)
@MainActor
struct VMURLGatewayTests {
    /// What the gateway did, in the order it did it.
    private enum Step: Equatable {
        case activated
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

    /// A gateway whose library read has already landed, over a seeded mock.
    private func makeGateway(
        _ commands: MockVMCommanding,
        trace: Trace,
        awaitReady: @escaping @Sendable () async -> Void = {}
    ) -> VMURLGateway {
        VMURLGateway(
            commands: commands,
            readiness: LibraryReadiness(awaitReady: awaitReady),
            activate: { trace.record(.activated) },
            summonLibrary: { trace.record(.summoned) },
            present: { trace.record(.presented($0)) })
    }

    private func makeSummary(name: String = "Sonoma", id: UUID = UUID()) -> VMSummary {
        VMSummary(id: id, name: name, status: "stopped", ipAddress: .unavailable)
    }

    // MARK: - Routes

    @Test("An open link runs the open verb on the VM it names")
    func openLinkRunsTheOpenVerb() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(commands.openSelectors == [.idOrName("Sonoma")])
        #expect(commands.revealSelectors.isEmpty)
        #expect(trace.presented.isEmpty)
    }

    @Test("A reveal link runs the reveal verb on the VM it names")
    func revealLinkRunsTheRevealVerb() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://reveal/Sonoma"))

        #expect(commands.revealSelectors == [.idOrName("Sonoma")])
        #expect(commands.openSelectors.isEmpty)
        #expect(trace.presented.isEmpty)
    }

    @Test("A link that runs brings the app forward and summons nothing")
    func aLinkThatRunsSummonsNothing() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open/Sonoma"))

        // The verb opens exactly the surface the link asked for; a library
        // window behind it is one nobody asked for.
        #expect(trace.steps == [.activated])
    }

    @Test("A verb refusal summons the library, in front, before it is shown")
    func aVerbRefusalSummonsTheLibraryBeforePresenting() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.notFound(.idOrName("Sonoma"))
        commands.openError = refusal
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(trace.steps == [.activated, .summoned, .presented(refusal)])
    }

    @Test("The verb waits for the app's first library read")
    func theVerbWaitsForTheFirstLibraryRead() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        let readiness = ReadinessGate()
        let gateway = makeGateway(
            commands, trace: trace, awaitReady: { await readiness.wait() })

        let link = try url("kernova://open/Sonoma")
        let handled = Task { await gateway.handle(link) }
        try await readiness.awaitWaiting()
        #expect(commands.openSelectors.isEmpty)
        #expect(trace.steps.isEmpty)

        readiness.open()
        await handled.value
        #expect(commands.openSelectors == [.idOrName("Sonoma")])
    }

    // MARK: - Refusals the core raises

    @Test("A name several VMs answer to is shown in the app")
    func anAmbiguousNameIsShownInTheApp() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.ambiguous(
            selector: .idOrName("Sonoma"),
            candidates: [makeSummary(), makeSummary()])
        commands.openError = refusal
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(trace.presented == [refusal])
    }

    @Test("A name no VM answers to is shown in the app")
    func aNameNoVMAnswersToIsShownInTheApp() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.notFound(.idOrName("Ghost"))
        commands.revealError = refusal
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://reveal/Ghost"))

        #expect(trace.presented == [refusal])
    }

    @Test("A VM whose state admits no open refuses the open route, in the app")
    func aStoppedVMRefusesTheOpenRoute() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.invalidState(
            vm: makeSummary(), current: .stopped, allowed: [.start, .reveal])
        commands.openError = refusal
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open/Sonoma"))

        #expect(trace.presented == [refusal])
    }

    // MARK: - Refusals the link itself earns

    @Test("A route Kernova does not offer is refused without running any verb")
    func anUnknownRouteIsRefusedWithoutCallingAnyVerb() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://start/Sonoma"))

        #expect(commands.openSelectors.isEmpty)
        #expect(commands.revealSelectors.isEmpty)
        #expect(
            trace.steps == [
                .activated, .summoned,
                .presented(.invalidArgument(VMURLRoute.Refusal.unknownRoute("start").message)),
            ])
    }

    @Test("A link naming no VM is refused, in the app, like every other refusal")
    func aLinkNamingNoVMIsRefused() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        await makeGateway(commands, trace: trace).handle(try url("kernova://open"))

        #expect(commands.openSelectors.isEmpty)
        #expect(
            trace.steps == [
                .activated, .summoned,
                .presented(.invalidArgument(VMURLRoute.Refusal.noVM(route: .open).message)),
            ])
    }

    @Test("A link Kernova cannot read is refused without waiting for the library read")
    func aMalformedLinkIsRefusedWithoutWaitingForTheLibrary() async throws {
        let commands = MockVMCommanding()
        let trace = Trace()
        let readiness = ReadinessGate()
        let gateway = makeGateway(
            commands, trace: trace, awaitReady: { await readiness.wait() })

        // Nothing about the library decides this refusal, so it never parks on
        // a read that a launch may still have in flight.
        await gateway.handle(try url("kernova://start/Sonoma"))

        #expect(!readiness.isWaiting)
        #expect(trace.presented.count == 1)
    }
}
