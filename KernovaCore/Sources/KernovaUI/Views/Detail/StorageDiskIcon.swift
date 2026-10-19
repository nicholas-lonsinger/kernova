import AppKit
import KernovaCore

/// SF Symbol name for a storage disk row's leading icon.
func diskIconSystemName(for disk: StorageDisk) -> String {
    if disk.kind == .usbMassStorage {
        return "opticaldisc"
    }
    return disk.isInternal ? "cylinder.split.1x2" : "externaldrive"
}
