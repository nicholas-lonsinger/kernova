import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("WindowAutosaveScope", .admissionGated)
struct WindowAutosaveScopeTests {
    @Test("The app's windows keep the autosave names every install has saved state under")
    func appNamesAreStable() throws {
        let app = WindowAutosaveScope.app
        let vmID = try #require(UUID(uuidString: "5E00A1A0-0000-4000-8000-000000000001"))

        #expect(app.mainWindowFrame == "KernovaMainWindow")
        #expect(app.mainToolbar == "KernovaMainToolbar")
        #expect(app.mainSplit == "KernovaMainSplit")
        #expect(app.settingsFrame == "KernovaSettings")
        #expect(app.displayToolbar == "KernovaVMDisplayToolbar")
        #expect(app.displayFrame(for: vmID) == "VMDisplay-5E00A1A0-0000-4000-8000-000000000001")
        #expect(app.clipboardFrame(for: vmID) == "Clipboard-5E00A1A0-0000-4000-8000-000000000001")
    }

    @Test("A scope that saves nothing hands out no name AppKit saves under")
    func unsavedNamesSaveNothing() {
        let unsaved = WindowAutosaveScope.unsaved()
        let vmID = UUID()

        #expect(!unsaved.savesState)
        #expect(unsaved.mainWindowFrame.isEmpty)
        #expect(unsaved.mainSplit == nil)
        #expect(unsaved.settingsFrame.isEmpty)
        #expect(unsaved.displayFrame(for: vmID).isEmpty)
        #expect(unsaved.clipboardFrame(for: vmID).isEmpty)
    }

    @Test("A scope that saves nothing shares its toolbar identifiers with no other scope")
    func unsavedToolbarsAreDistinct() {
        let first = WindowAutosaveScope.unsaved()
        let second = WindowAutosaveScope.unsaved()

        #expect(first.mainToolbar != second.mainToolbar)
        #expect(first.displayToolbar != second.displayToolbar)
        #expect(first.mainToolbar != WindowAutosaveScope.app.mainToolbar)
        #expect(first.displayToolbar != WindowAutosaveScope.app.displayToolbar)
    }
}
