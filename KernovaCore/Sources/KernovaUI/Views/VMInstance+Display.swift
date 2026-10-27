import AppKit
import KernovaCommandModel
import KernovaCore
import KernovaKit

/// AppKit-surface properties derived from a VM's status.
extension VMInstance {
    /// The `VZVirtualMachineView` properties this VM's display should carry
    /// right now.
    ///
    /// The one derivation of the set, so the inline display and the display
    /// window cannot disagree — and reading it inside an observation `track`
    /// closure registers exactly what it depends on, `displayMode` included.
    var displayViewSettings: VMDisplayViewSettings {
        let capturesSystemKeys =
            switch configuration.systemKeyForwarding {
            case .never: false
            case .fullscreenOnly: isInFullscreen
            case .always: true
            }
        return VMDisplayViewSettings(
            automaticallyReconfiguresDisplay: configuration.displayAutoResizes,
            capturesSystemKeys: capturesSystemKeys)
    }

    /// Color used to tint the sidebar's OS icon.
    ///
    /// A VM another copy of Kernova holds is the running color dimmed.
    /// Running-while-awaiting-network-reattach is orange, and the remaining
    /// states follow `status`.
    var statusDisplayNSColor: NSColor {
        if heldByAnotherCopy { return StatusColor.heldByAnotherCopy }
        if status == .running && networkAttachmentPending { return StatusColor.warning }
        switch status {
        // A concrete gray (not `.secondaryLabelColor`) so the icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        case .stopped: return .systemGray
        case .starting, .suspended, .saving, .snapshotting, .cloning, .restoring, .installing,
            .initialBoot:
            return StatusColor.warning
        case .running: return StatusColor.running
        case .paused: return StatusColor.pausedInMemory
        case .error: return StatusColor.error
        }
    }
}
