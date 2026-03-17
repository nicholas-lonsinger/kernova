import SwiftUI

/// Display-layer properties that distinguish cold-paused ("Suspended") from live-paused ("Paused").
extension VMInstance {

    /// Display name that distinguishes cold-paused ("Suspended") from live-paused ("Paused").
    var statusDisplayName: String {
        isColdPaused ? "Suspended" : status.displayName
    }

    /// Display color that distinguishes cold-paused (orange) from live-paused (yellow).
    var statusDisplayColor: Color {
        isColdPaused ? .orange : status.statusColor
    }

    /// Tooltip explaining the paused variant, or `nil` for non-paused states.
    var statusToolTip: String? {
        guard status == .paused else { return nil }
        return isColdPaused
            ? "VM state is saved to disk"
            : "VM is paused in memory"
    }
}
