import AppKit

@testable import KernovaUI

/// The visible frame a test's Settings window fits inside, whatever window
/// it is in: ``WindowStage/offDesktopVisibleFrame``.
@MainActor
func offDesktopVisibleFrame(_: NSWindow?) -> NSRect? {
    WindowStage.offDesktopVisibleFrame
}
