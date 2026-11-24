import Foundation

/// The base title of each Virtual Machine and File menu command that names a
/// verb without context — what the menus, the toolbar and the sidebar title
/// that command with, and what ``VMVerbVocabulary/app`` names the verb by in
/// the app's own sentences.
///
/// A menu item that asks for more appends its own ellipsis.
package enum AppCommandTitle {
    package static let newVirtualMachine = "New Virtual Machine"
    package static let start = "Start"
    package static let pause = "Pause"
    package static let resume = "Resume"
    package static let stop = "Stop"
    package static let restart = "Restart"
    package static let suspend = "Suspend"
    package static let takeSnapshot = "Take Snapshot"
    package static let revertToSnapshot = "Revert to Snapshot"
    package static let rename = "Rename"
    /// The verb the Clone items' titles open with ("Clone as Exact Copy").
    package static let clone = "Clone"
    package static let showInFinder = "Show in Finder"
    package static let moveToTrash = "Move to Trash"
}
