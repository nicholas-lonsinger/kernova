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
}
