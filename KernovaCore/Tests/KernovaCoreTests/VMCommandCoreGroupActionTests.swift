import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The one group-action executor every door shares: which VMs each action
/// acts on, read from capabilities, and what it reports for the rest.
@Suite("VMCommandCore group actions", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreGroupActionTests {
    private let preferences = makeTestPreferences()

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), networks: networks, organization: organization,
                preferences: preferences))
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String, guestOS: VMGuestOS = .linux, phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library, preferences: preferences,
            mutate: mutate)
    }

    /// One VM in each state a group action reads differently, in a folder
    /// holding them all in this order.
    private struct Library {
        let folder: VMGroupReference
        let stopped: VMInstance
        let running: VMInstance
        let paused: VMInstance
        let suspended: VMInstance
        let owesSetup: VMInstance
    }

    private func makeLibrary(in harness: Harness) throws -> Library {
        let stopped = makeInstance(in: harness, name: "Stopped")
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        let paused = makeInstance(in: harness, name: "Paused", phase: .livePaused(sessionID: UUID()))
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let owesSetup = makeInstance(in: harness, name: "Fresh", guestOS: .macOS, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let folder = try harness.library.organization.createFolder(
            named: "Lab", members: [stopped, running, paused, suspended, owesSetup].map(\.id))
        return Library(
            folder: VMGroupReference(.folder, named: folder.id.uuidString), stopped: stopped, running: running,
            paused: paused, suspended: suspended, owesSetup: owesSetup)
    }

    private func outcomes(_ report: VMGroupActionReport) -> [String: VMGroupActionOutcome] {
        Dictionary(uniqueKeysWithValues: report.results.map { ($0.vm.name, $0.outcome) })
    }

    // MARK: - Which VMs each action acts on

    @Test("Suspend All saves running and paused guests; Stop All asks only the running one to shut down")
    func suspendAndStopAll() async throws {
        let harness = makeHarness()
        let library = try makeLibrary(in: harness)

        let stopped = try await harness.core.groupAction(.stop, on: library.folder)
        #expect(outcomes(stopped)["Running"] == .done(verb: .stop))
        #expect(stopped.results.filter { $0.outcome == .done(verb: .stop) }.count == 1)
        #expect(harness.virtualization.stopCallCount == 1)
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(library.suspended.hasSaveFile)
        #expect(library.paused.status == .paused)

        let harness2 = makeHarness()
        let library2 = try makeLibrary(in: harness2)
        let suspended = try await harness2.core.groupAction(.suspend, on: library2.folder)
        #expect(
            outcomes(suspended) == [
                "Stopped": .passedOver(reason: .state), "Running": .done(verb: .suspend),
                "Paused": .done(verb: .suspend), "Suspended": .passedOver(reason: .state),
                "Fresh": .passedOver(reason: .state),
            ])
        #expect(harness2.virtualization.saveCallCount == 2)
    }

    // MARK: - What it reports

    @Test("A VM whose start asks to confirm a shared machine ID is skipped and listed; the rest start")
    func consentNeedingVMIsSkipped() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([7, 7, 7])
        makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let twin = makeInstance(in: harness, name: "Twin") { $0.genericMachineIdentifierData = identity }
        let other = makeInstance(in: harness, name: "Other")
        try harness.library.organization.createFolder(named: "Pair", members: [twin.id, other.id])

        // Counted: the question is the start's, asked only when it commits.
        #expect(try harness.core.concernedCounts(in: VMGroupReference(.folder, named: "Pair"))[.start] == 2)
        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Pair"))

        guard case .needsAnswer(.start, let question) = report.results[0].outcome,
            case .confirmationRequired(let prompt) = question
        else {
            Issue.record("expected the twin skipped for a confirmation, got \(report.results[0].outcome)")
            return
        }
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
        #expect(report.results[1].outcome == .done(verb: .start))
        #expect(twin.status == .stopped)
        #expect(other.status == .running)
        #expect(report.undone.map(\.vm.name) == ["Twin"])
        #expect(report.undoneTitle == "Couldn\u{2019}t Start Every VM in \u{201C}Pair\u{201D}")
        #expect(
            report.undoneMessage
                == "Skipped Twin: \(prompt.message) Start it on its own to answer.")
    }

    // MARK: - Failures on the event stream

    /// A restore that fails rests the VM back on its saved state, so its status
    /// carries nothing the stream could report it from.
    @Test("A member's failure that rests the VM where it began goes on the event stream, once")
    func memberFailureIsBroadcast() async throws {
        let harness = makeHarness()
        harness.virtualization.restoreError = VirtualizationError.restoreFailed(
            underlying: NSError(domain: "test", code: 1))
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        try harness.library.organization.createFolder(named: "Lab", members: [suspended.id])
        let events = harness.core.events()

        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))

        guard case .failed = report.results.first?.outcome else {
            Issue.record("reported \(String(describing: report.results.first?.outcome))")
            return
        }
        #expect(suspended.status == .suspended)
        #expect(try await harness.wired.failureMessages(of: suspended, on: events).count == 1)
    }

    // MARK: - Error mapping

    @Test("A question is a VM to answer for; the quit and another copy's hold are nobody's failure; the rest fail")
    func refusalsMapToOutcomes() {
        let vm = VMSummary(id: UUID(), name: "VM", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
        let confirmation = CommandError.confirmationRequired(
            ConfirmationPrompt(
                kind: .startBesideSharedMachineIdentity, title: "T", message: "M", confirmTitle: "C",
                dismissTitle: "D"))
        let account = CommandError.guestAccountPasswordRequired(
            GuestAccountPrompt(vm: vm, username: "me", fullName: "Me", message: "M"))
        for question in [confirmation, account] {
            #expect(
                VMCommandCore.outcome(of: question, takenBy: .resume)
                    == .needsAnswer(verb: .resume, question: question.dto))
        }
        #expect(
            VMCommandCore.outcome(of: .terminating, takenBy: .start)
                == .passedOver(reason: .refused(error: .terminating)))
        // A step refusal names a step of its own, which a group action takes
        // for nobody.
        let step = CommandError.stepRequired(
            StepRequirement(
                message: "M",
                routes: [
                    StepRoute(title: "Own", steps: [.setConfiguration(vm: vm, assignments: [])], ending: .refusedVerb)
                ]))
        #expect(VMCommandCore.outcome(of: step, takenBy: .resume) == .failed(error: step.dto))
        let failed = CommandError.operationFailed(verb: .start, message: "No.")
        #expect(VMCommandCore.outcome(of: failed, takenBy: .start) == .failed(error: failed.dto))
        #expect(
            VMCommandCore.outcome(of: .busy(vm: vm, operation: "saving"), takenBy: .suspend)
                == .failed(error: .busy(vm: vm, operation: "saving")))
        #expect(VMCommandCore.outcome(of: .heldByAnotherCopy(vm: vm), takenBy: .start) == .passedOver(reason: .state))
    }
}
