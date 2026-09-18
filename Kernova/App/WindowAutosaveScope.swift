import AppKit

/// The names the app's windows save their frames, split positions, and toolbar
/// layouts under, which AppKit keeps in `UserDefaults.standard` whatever store
/// the app's preferences wrap.
struct WindowAutosaveScope: Sendable {
    /// Prepended to every name; empty for the app's own windows.
    let prefix: String

    /// The app's own windows.
    static let app = WindowAutosaveScope(prefix: "")

    var mainWindowFrame: NSWindow.FrameAutosaveName { prefix + "KernovaMainWindow" }
    var mainToolbar: NSToolbar.Identifier { prefix + "KernovaMainToolbar" }
    var mainSplit: NSSplitView.AutosaveName { prefix + "KernovaMainSplit" }
    var settingsFrame: NSWindow.FrameAutosaveName { prefix + "KernovaSettings" }

    // RATIONALE (2026-09-18): one toolbar identifier shared by every VM's
    // display window, unlike the per-VM frame name — "Toolbars with the same
    // identifier are implicitly synchronized so that they maintain the same
    // state" (NSToolbar.h, `initWithIdentifier:`), so a customized layout applies
    // to all display windows and persists as a single configuration.
    var displayToolbar: NSToolbar.Identifier { prefix + "KernovaVMDisplayToolbar" }

    func displayFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        prefix + "VMDisplay-\(vmID)"
    }

    func clipboardFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        prefix + "Clipboard-\(vmID.uuidString)"
    }
}
