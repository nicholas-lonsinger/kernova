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
}
