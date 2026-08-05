import Foundation
import KernovaKit

/// Pure text mappers for the guest agent's menu-bar dropdown.
enum AgentMenuText {
    static func about() -> String { "About Kernova Guest Agent" }

    /// Shown only when the host bundles a newer agent.
    static func updateAvailableLine(bundled: String) -> String {
        "Update available — host bundles \(bundled)"
    }

    static func hostStatusLine(_ state: HostConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting to host…"
        case .connected: return "Connected to host"
        case .unresponsive: return "Host not responding"
        }
    }

    static func statusSubmenu() -> String { "Status" }

    static func logForwardingLine(_ enabled: Bool) -> String {
        "Log Forwarding: \(enabled ? "enabled" : "disabled")"
    }

    static func clipboardLine(_ activity: ClipboardActivity) -> String {
        switch activity {
        case .enabled: return "Clipboard: enabled"
        case .offeredToHost: return "Clipboard: shared with host"
        case .offeredFromHost: return "Clipboard: shared from host"
        case .sentToHost: return "Clipboard: sent to host"
        case .receivedFromHost: return "Clipboard: received from host"
        case .pasteRefused(let code): return "Clipboard: \(pasteRefusalDetail(code))"
        case .disabled: return "Clipboard: disabled"
        }
    }

    /// Why a paste of the host's clipboard did not happen, per failure code.
    ///
    /// `copyTooLarge` and `pasteIncompleteSet` are host-only refusals that never
    /// reach the guest, so they read as the generic failure.
    private static func pasteRefusalDetail(_ code: ClipboardErrorCode) -> String {
        switch code {
        case .pasteTooLarge:
            return
                "too large to paste — over the \(ClipboardStreamTuning.maxDeadlineSafePasteDisplayLimit) transfer limit"
        case .pasteDiskFull: return "not enough disk space to paste"
        case .pasteTimeout: return "paste timed out"
        case .pasteFailed, .copyTooLarge, .pasteIncompleteSet: return "paste failed"
        }
    }

    static func quit() -> String { "Quit Kernova Guest Agent" }
}
