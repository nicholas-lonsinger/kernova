import AppKit
import Testing

@testable import Kernova

@Suite("VMDisplayBackingView Tests")
@MainActor
struct VMDisplayBackingViewTests {
    @Test("update carries automaticallyReconfiguresDisplay through to the machine view")
    func updateAppliesAutoResizeFlag() {
        let backing = VMDisplayBackingView(frame: .zero)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)

        backing.update(
            virtualMachine: nil, isPaused: false, transitionText: nil,
            automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.update(
            virtualMachine: nil, isPaused: false, transitionText: nil,
            automaticallyReconfiguresDisplay: true)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
    }

    @Test("apply reaches the machine view without an update pass")
    func applyAutoResizeFlagStandalone() {
        let backing = VMDisplayBackingView(frame: .zero)

        backing.apply(automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        // Re-applying the same value is a no-op, and the next change still lands.
        backing.apply(automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.apply(automaticallyReconfiguresDisplay: true)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
    }

    @Test("detach clears the machine view and leaves the auto-resize flag alone")
    func detachClearsWithoutTouchingTheFlag() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.apply(automaticallyReconfiguresDisplay: false)

        backing.detach()

        #expect(backing.machineView.virtualMachine == nil)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
    }
}
