import Foundation
import KernovaProtocol

/// Pure text mappers for the guest agent's menu-bar dropdown.
///
/// Free of AppKit so they're trivially unit-testable; `GuestAgentStatusItemController`
/// calls them when (re)building menu lines in `menuNeedsUpdate`.
enum GuestAgentMenuText {
    /// Identity header line.
    static func identity() -> String { "Kernova Guest Agent" }

    /// Version + build line, with an update suffix derived from the host's
    /// bundled version. `.unknown` (host hasn't reported one) shows no suffix.
    static func versionLine(
        version: String,
        build: String,
        update: KernovaVersionComparison.UpdateState
    ) -> String {
        let base = "Version \(version) (\(build))"
        switch update {
        case .unknown:
            return base
        case .upToDate:
            return base + " · Up to date"
        case .updateAvailable(let bundled):
            return base + " · Update available (host has \(bundled))"
        }
    }

    /// Host control-channel status line.
    static func hostStatusLine(_ state: HostConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting to host…"
        case .connected: return "Connected to host"
        case .unresponsive: return "Host not responding"
        }
    }

    /// Most-recent clipboard activity line.
    static func clipboardLine(_ activity: ClipboardActivity) -> String {
        switch activity {
        case .idle: return "Clipboard: idle"
        case .offeredToHost: return "Clipboard: shared with host"
        case .receivedFromHost: return "Clipboard: received from host"
        }
    }

    /// Quit command title.
    static func quit() -> String { "Quit Kernova Guest Agent" }
}
