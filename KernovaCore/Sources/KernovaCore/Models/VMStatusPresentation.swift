import Foundation
import KernovaCommandModel

extension VMStatus {
    /// Overlay label for save/restore transitions, or `nil` for all other
    /// states.
    ///
    /// AppKit-surface copy rather than wire vocabulary, so it stays with the
    /// overlays that render it.
    package var transitionLabel: String? {
        switch self {
        case .saving: "Suspending\u{2026}"
        case .snapshotting: "Taking Snapshot\u{2026}"
        case .cloning: "Cloning\u{2026}"
        case .restoring: "Restoring\u{2026}"
        default: nil
        }
    }
}
