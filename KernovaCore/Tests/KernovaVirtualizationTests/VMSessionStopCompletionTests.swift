import Foundation
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization

/// What a stop's completion tells the VM it was sent to, and how a session a
/// stop is pending on ends — the completion and `didStopWithError` arrive in
/// either order when the VM's process is ended from outside.
@Suite("VMSession Stop Completion Tests", .caseScoped)
@MainActor
struct VMSessionStopCompletionTests {
    /// What ending a VM's process from outside reports, through the stop's
    /// completion and the delegate alike.
    private static let stoppedUnexpectedly = NSError(
        domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "The virtual machine stopped unexpectedly."])

    @Test("A stop's error ends the session unless the VM is still live; a success always does")
    func completionEndsTheSessionUnlessTheVMIsLive() {
        // Every state `VZVirtualMachine.h` declares, and whether a VM in it
        // is still live.
        let states: [(VZVirtualMachine.State, live: Bool)] = [
            (.stopped, false), (.error, false),
            (.running, true), (.paused, true), (.starting, true), (.pausing, true),
            (.resuming, true), (.stopping, true), (.saving, true), (.restoring, true),
        ]
        for (state, live) in states {
            let failed = VMSession.stopCompletionEvent(Self.stoppedUnexpectedly, state: state)
            if live {
                guard case .stopDidFail = failed else {
                    Issue.record("An error on a live VM (\(state.rawValue)) ended its session")
                    continue
                }
            } else {
                guard case .stopDidComplete = failed else {
                    Issue.record("An error on a VM no longer live (\(state.rawValue)) failed the stop")
                    continue
                }
            }
            guard case .stopDidComplete = VMSession.stopCompletionEvent(nil, state: state) else {
                Issue.record("A successful stop (\(state.rawValue)) did not end the session")
                continue
            }
        }
    }

    /// The order the stop's completion and `didStopWithError` arrive in.
    enum Arrival: CaseIterable, Sendable {
        case completionFirst
        case delegateFirst
    }

    @Test(
        "A Force Restart whose VM process is ended from outside powers the VM off and restarts it, in either order",
        arguments: Arrival.allCases)
    func processEndedDuringAForceRestartPowersOff(_ arrival: Arrival) async throws {
        let session = UUID()
        let instance = VMInstanceFixture.make(phase: .running(sessionID: session))
        let seen = Seen()
        instance.activity.onSessionStoppedWithError = { seen.stoppedWithError.append($0) }
        let boot = VMFollowUp(scope: .vm, rank: .ordinary, request: .start(recovery: false)) { outcome in
            seen.boots += 1
            outcome.resolve(.success(()))
        }
        let stop = try instance.activity.forceStop(continuingWith: boot) {}

        // What the session delivers for the completion: the process is gone,
        // so the VM is in the error state.
        let completion = VMSession.stopCompletionEvent(Self.stoppedUnexpectedly, state: .error)
        let delegate = VMSessionEvent.didStopWithError(Self.stoppedUnexpectedly)
        let events = arrival == .completionFirst ? [completion, delegate] : [delegate, completion]
        for event in events { instance.activity.deliverSessionEvent(event, from: session) }

        try await stop.value()
        try await boot.outcome.value()
        #expect(seen.boots == 1)
        #expect(instance.phase == .stopped)
        #expect(instance.activity.lastFailure == nil)
        #expect(seen.stoppedWithError.isEmpty)
    }
}

/// What the hooks and the owed boot saw.
@MainActor
private final class Seen {
    var boots = 0
    var stoppedWithError: [String] = []
}
