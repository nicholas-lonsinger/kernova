import AppKit

@testable import KernovaUI

/// The visible frame a test's Settings window fits inside, whatever window
/// it is in: ``WindowStage/offDesktopVisibleFrame``.
@MainActor
func offDesktopVisibleFrame(_ window: NSWindow?) -> NSRect? {
    WindowStage.offDesktopVisibleFrame
}

/// Enough VMs that the Reminders pane outgrows the tallest window
/// ``WindowStage/offDesktopVisibleFrame`` can hold, at well under one row per
/// 20 points of that height.
@MainActor
func overflowingVMCount() -> Int {
    Int(SettingsPaneMetrics.maxHeight(in: nil, visibleFrame: WindowStage.offDesktopVisibleFrame) / 20)
}
