import AppKit
import Foundation
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The color a VM's status draws in, which the AppKit layer maps from the
/// core's status.
@Suite("VMInstance status color", .caseScoped)
@MainActor
struct VMInstanceStatusColorTests {
    @Test("statusDisplayNSColor is orange when suspended and the in-memory colour when live-paused")
    func statusDisplayNSColorSuspendedAndPaused() {
        #expect(VMInstanceFixture.make(phase: .suspended).statusDisplayNSColor == .systemOrange)
        #expect(
            VMInstanceFixture.make(phase: .livePaused(sessionID: UUID())).statusDisplayNSColor
                == StatusColor.pausedInMemory)
    }

    @Test("statusDisplayNSColor maps non-paused states")
    func statusDisplayNSColorByStatus() {
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(VMInstanceFixture.make(phase: .stopped).statusDisplayNSColor == .systemGray)
        #expect(VMInstanceFixture.make(phase: .running(sessionID: UUID())).statusDisplayNSColor == .systemGreen)
        #expect(
            VMInstanceFixture.make(phase: .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))
                .statusDisplayNSColor == .systemOrange)
        #expect(VMInstanceFixture.make(phase: .failed(message: "Boot failed.")).statusDisplayNSColor == .systemRed)
    }

    @Test("A running VM awaiting network reattach shows the warning tint")
    func networkPendingShowsWarningTint() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture(phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().networkAttachmentPending = true

        #expect(instance.statusDisplayNSColor == StatusColor.warning)
    }

    @Test("A VM another copy holds draws in the dimmed running color")
    func heldByAnotherCopyDrawsDimmed() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()
        storage.files.holdElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()

        #expect(instance.statusDisplayNSColor == StatusColor.heldByAnotherCopy)
    }
}
