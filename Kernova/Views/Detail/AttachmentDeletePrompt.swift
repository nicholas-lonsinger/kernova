import Foundation


/// The confirmation a per-row storage/removable delete should present.
///
/// The trailing Cancel button is added by the presenter, not modeled here.
struct AttachmentDeletePrompt: Equatable {
    /// A non-cancel action and the file disposition it implies.
    enum Action: Equatable {
        /// Remove the entry AND move its file to the Trash.
        case moveToTrash
        /// Remove the entry; leave the file in place.
        case removeFromVM
    }

    let title: String
    let message: String
    /// Offered actions in display order; the first is the default button.
    let actions: [Action]
}
