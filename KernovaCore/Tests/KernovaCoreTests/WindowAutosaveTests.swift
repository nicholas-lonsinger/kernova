import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("WindowAutosave", .caseScoped)
struct WindowAutosaveTests {
    @Test("The app's windows keep the autosave names every install has saved state under")
    func appNamesAreStable() throws {
        let app = WindowAutosave.app
        let vmID = try #require(UUID(uuidString: "5E00A1A0-0000-4000-8000-000000000001"))

        #expect(app.mainWindowFrame == "KernovaMainWindow")
        #expect(app.mainToolbar == "KernovaMainToolbar")
        #expect(app.mainSplit == "KernovaMainSplit")
        #expect(app.settingsFrame == "KernovaSettings")
        #expect(app.displayToolbar == "KernovaVMDisplayToolbar")
        #expect(app.displayFrame(for: vmID) == "VMDisplay-5E00A1A0-0000-4000-8000-000000000001")
        #expect(app.clipboardFrame(for: vmID) == "Clipboard-5E00A1A0-0000-4000-8000-000000000001")
        #expect(
            app.guestAgentStatusFrame(for: vmID) == "GuestAgentStatus-5E00A1A0-0000-4000-8000-000000000001")
    }

    @Test("Unsaved names hand out no name AppKit saves under")
    func unsavedNamesSaveNothing() {
        let unsaved = WindowAutosave.unsaved()
        let vmID = UUID()

        #expect(!unsaved.savesState)
        #expect(unsaved.mainWindowFrame.isEmpty)
        #expect(unsaved.mainSplit == nil)
        #expect(unsaved.settingsFrame.isEmpty)
        #expect(unsaved.displayFrame(for: vmID).isEmpty)
        #expect(unsaved.clipboardFrame(for: vmID).isEmpty)
        #expect(unsaved.guestAgentStatusFrame(for: vmID).isEmpty)
    }

    @Test("Each set of unsaved names shares its toolbar identifiers with no other")
    func unsavedToolbarsAreDistinct() {
        let first = WindowAutosave.unsaved()
        let second = WindowAutosave.unsaved()

        #expect(first.mainToolbar != second.mainToolbar)
        #expect(first.displayToolbar != second.displayToolbar)
        #expect(first.mainToolbar != WindowAutosave.app.mainToolbar)
        #expect(first.displayToolbar != WindowAutosave.app.displayToolbar)
    }
}
