import Foundation

@testable import Kernova

extension WindowAutosave {
    /// Names AppKit saves nothing under, with toolbar identifiers minted here
    /// so no other stage's toolbar shares their configuration.
    static func unsaved() -> WindowAutosave {
        WindowAutosave(savesState: false, mainToolbar: UUID().uuidString, displayToolbar: UUID().uuidString)
    }
}
