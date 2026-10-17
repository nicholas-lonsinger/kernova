import Foundation

/// The names AppKit saves the app's window state under — frame, split position
/// and toolbar layout, in `UserDefaults.standard` whatever store the app's
/// preferences wrap — as a ``WindowStage`` hands them to its windows.
struct WindowAutosave: Sendable {
    /// Whether AppKit saves and restores what these names cover.
    let savesState: Bool

    let mainToolbar: String

    /// Shared by every VM's display window, unlike the per-VM frame name.
    /// "Toolbars with the same identifier are implicitly synchronized so that
    /// they maintain the same state" (NSToolbar.h, `initWithIdentifier:`), so a
    /// customized layout applies to all display windows as one configuration.
    let displayToolbar: String

    /// The names the app's own windows save under.
    static let app = WindowAutosave(
        savesState: true, mainToolbar: "KernovaMainToolbar", displayToolbar: "KernovaVMDisplayToolbar")

    var mainWindowFrame: String { frame("KernovaMainWindow") }
    var mainSplit: String? { savesState ? "KernovaMainSplit" : nil }
    var settingsFrame: String { frame("KernovaSettings") }
    var configCheckFrame: String { frame("KernovaConfigCheck") }

    func displayFrame(for vmID: UUID) -> String { frame("VMDisplay-\(vmID)") }

    func clipboardFrame(for vmID: UUID) -> String {
        frame("Clipboard-\(vmID.uuidString)")
    }

    /// AppKit reads an empty name as "don't save this window's frame".
    private func frame(_ name: String) -> String {
        savesState ? name : ""
    }
}
