import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
    @MainActor
    private final class ReadinessGate {
        /// Fires when the gateway starts waiting, and again when it is let go.
        private let gate = AsyncGate()
        private var isOpen = false

        /// Whether the gateway is parked on the readiness await.
        private(set) var isWaiting = false

        /// Suspends until ``open()``, as the app's first library read does.
        func wait() async {
            isWaiting = true
            gate.notify()
            try? await gate.wait { self.isOpen }
        }

        /// Lands the library read.
        func open() {
            isOpen = true
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
}
