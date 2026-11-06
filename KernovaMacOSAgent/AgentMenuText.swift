import Foundation
import KernovaKit

/// Pure text mappers for the guest agent's menu-bar dropdown.
enum AgentMenuText {
    static func about() -> String { "About Kernova Guest Agent" }

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
        case .pasteRefused(let code, let pasteLimitBytes):
            return "Clipboard: \(pasteRefusalDetail(code, pasteLimitBytes: pasteLimitBytes))"
        case .copyCarriedNothing: return "Clipboard: nothing in that copy could be shared"
        case .copyPartlyCarried(let skipped):
            return "Clipboard: shared with host — \(skipped) item\(skipped == 1 ? "" : "s") not in full"
        case .copyWithdrawn(filesOnly: false):
            return "Clipboard: the Mac withdrew its copy, so it was removed"
        case .copyWithdrawn(filesOnly: true):
            return "Clipboard: the Mac withdrew its copy, so its files were removed; the rest is still here"
        case .disabled: return "Clipboard: disabled"
        }
    }

    /// Why a paste of the host's clipboard did not happen, per failure code.
    ///
    /// The drop and drag codes are outcomes the host reports rather than ones
    /// the guest receives, so they read as the generic failure.
    private static func pasteRefusalDetail(
        _ code: ClipboardErrorCode, pasteLimitBytes: Int?
    ) -> String {
        switch code {
        case .pasteTooLarge:
            guard let pasteLimitBytes else { return "too large to paste" }
            return
                "too large to paste — over the \(ClipboardPasteLimit.displayLimit(pasteLimitBytes)) transfer limit"
        case .pasteFailed, .dropDiskFull, .dropDownloadsDenied, .dropFailed, .dropUnpackFailed,
            .dragItemUnavailable:
            return "paste failed"
        }
    }

    static func quit() -> String { "Quit Kernova Guest Agent" }
}
