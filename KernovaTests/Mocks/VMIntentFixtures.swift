import Foundation
import KernovaKit

/// The command-core reads the App Intents suites build their entities from.
///
/// Every field has a default, so a test names only what it asserts on.
enum VMIntentFixtures {
    static func info(
        id: UUID = UUID(),
        name: String = "Wired",
        status: String = "stopped",
        guestOS: String = "linux",
        cpuCount: Int = 2,
        memoryBytes: UInt64 = 4 << 30,
        diskSizeInGB: Int = 64,
        networkMode: String? = "nat",
        macAddress: String? = "aa:bb:cc:dd:ee:ff",
        ipAddress: String? = nil,
        agentStatus: String = "notInstalled",
        hasSavedState: Bool = false,
        isEphemeral: Bool = false,
        snapshotCount: Int = 0,
        bundlePath: String = "/tmp/vm.kernova"
    ) -> VMInfo {
        VMInfo(
            id: id,
            name: name,
            status: status,
            guestOS: guestOS,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            diskSizeInGB: diskSizeInGB,
            networkMode: networkMode,
            macAddress: macAddress,
            ipAddress: ipAddress,
            agentStatus: agentStatus,
            hasSavedState: hasSavedState,
            isEphemeral: isEphemeral,
            snapshotCount: snapshotCount,
            bundlePath: bundlePath)
    }

    static func snapshot(
        id: UUID = UUID(),
        name: String = "Before Update",
        notes: String = "",
        kind: String = "warm",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isCurrent: Bool = false,
        isEphemeralBaseline: Bool = false
    ) -> SnapshotSummary {
        SnapshotSummary(
            id: id,
            name: name,
            notes: notes,
            kind: kind,
            createdAt: createdAt,
            isCurrent: isCurrent,
            isEphemeralBaseline: isEphemeralBaseline)
    }
}
