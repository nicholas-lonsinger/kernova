import Foundation
import KernovaKit

extension VMStatus {
    /// Overlay label for save/restore transitions, or `nil` for all other
    /// states.
    ///
    /// AppKit-surface copy rather than wire vocabulary, so it stays with the
    /// overlays that render it.
    var transitionLabel: String? {
        switch self {
        case .saving: "Suspending\u{2026}"
        case .snapshotting: "Taking Snapshot\u{2026}"
        case .restoring: "Restoring\u{2026}"
        default: nil
        }
    }
}
