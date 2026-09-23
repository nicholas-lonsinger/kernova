import AppKit

/// Whether a window saves its frame, split position, and toolbar layout, and
/// under what name — AppKit keeps them in `UserDefaults.standard` whatever
/// store the app's preferences wrap.
struct WindowAutosaveScope: Sendable {
    /// Whether AppKit saves and restores what these names cover.
    let savesState: Bool

    let mainToolbar: NSToolbar.Identifier

    /// Shared by every VM's display window, unlike the per-VM frame name.
    /// "Toolbars with the same identifier are implicitly synchronized so that
    /// they maintain the same state" (NSToolbar.h, `initWithIdentifier:`), so a
    /// customized layout applies to all display windows as one configuration.
    let displayToolbar: NSToolbar.Identifier

    /// The app's own windows.
    static let app = WindowAutosaveScope(
        savesState: true, mainToolbar: "KernovaMainToolbar", displayToolbar: "KernovaVMDisplayToolbar")

    /// Windows AppKit saves nothing for. Their toolbars answer to identifiers
    /// minted here, which same-identifier synchronization then keeps to the one
    /// scope.
    static func unsaved() -> WindowAutosaveScope {
        WindowAutosaveScope(
            savesState: false, mainToolbar: UUID().uuidString, displayToolbar: UUID().uuidString)
    }

    var mainWindowFrame: NSWindow.FrameAutosaveName { frame("KernovaMainWindow") }
    var mainSplit: NSSplitView.AutosaveName? { savesState ? "KernovaMainSplit" : nil }
    var settingsFrame: NSWindow.FrameAutosaveName { frame("KernovaSettings") }

    func displayFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName { frame("VMDisplay-\(vmID)") }

    func clipboardFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        frame("Clipboard-\(vmID.uuidString)")
    }

    /// AppKit reads an empty name as "don't save this window's frame".
    private func frame(_ name: NSWindow.FrameAutosaveName) -> NSWindow.FrameAutosaveName {
        savesState ? name : ""
    }
}
