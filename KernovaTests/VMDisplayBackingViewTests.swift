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
}
