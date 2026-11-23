import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// The Storage panel's own behavior, drilled into through the shell.
@Suite("VM Settings Storage Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsStoragePanelTests {
    // MARK: - Per-row delete confirmation prompt

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Scratch", isInternal: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.alternatives.map(\.title) == ["Remove from VM"])
        // Keeping the file is the whole of what the alternative changes, and
        // it destroys nothing.
        #expect(prompt.alternatives.map(\.keepsFile) == [true])
        #expect(prompt.alternatives.map(\.isDestructive) == [false])
    }
}
