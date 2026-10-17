import AppKit

@testable import KernovaUI

/// Enough VMs that the Reminders pane outgrows the tallest window the screen
/// can hold, at well under one row per 20 points of that height.
@MainActor
func overflowingVMCount() -> Int {
    Int((SettingsPaneMetrics.maxHeight(in: nil) ?? 1_000) / 20)
}
