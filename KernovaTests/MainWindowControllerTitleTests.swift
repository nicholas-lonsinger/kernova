import Foundation
import Testing

@testable import Kernova

@Suite("MainWindowController window title")
@MainActor
struct MainWindowControllerTitleTests {
    @Test("With nothing selected the window is titled Kernova alone")
    func noSelectionIsTitledKernova() {
        #expect(MainWindowController.windowTitle(for: nil) == "Kernova")
    }

    @Test("A selected VM titles the window with its name")
    func selectedVMTitlesTheWindow() {
        let entry = LibraryEntry.vm(VMInstanceFixture.make(name: "Alpha"))
        #expect(MainWindowController.windowTitle(for: entry) == "Kernova — Alpha")
    }

    @Test("A selected arrival titles the window with its name")
    func selectedArrivalTitlesTheWindow() {
        let arrival = VMArrival.inert(
            .importing,
            configuration: VMConfiguration(name: "Arriving", guestOS: .linux, bootMode: .efi))
        #expect(MainWindowController.windowTitle(for: .arriving(arrival)) == "Kernova — Arriving")
    }
}
