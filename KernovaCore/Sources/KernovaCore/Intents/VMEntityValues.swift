import AppIntents
import Foundation
import KernovaCommandModel

// The pickers a Virtual Machine's and a Guest Agent's closed-set properties are
// shown and found by. Each mirrors a library type for the reason
// ``VMStopMethod`` states, its `init(_:)` exhaustive over that type, and titles
// each case in the words the app gives that value. Those words are spelled out
// again here because the metadata processor takes only a string literal as a
// case's title: one read from the library type fails the build with
// "Unsupported value for interpolated string segment: runtimeValue" (Xcode
// 27B52).

/// A VM's ``VMReportedStatus``, titled as
/// ``VMReportedStatus/displayName(heldByAnotherCopy:)`` reads it for a VM no
/// other copy of Kernova holds.
enum VMState: String, AppEnum {
    case stopped
    case starting
    case running
    case paused
    case suspended
    case saving
    case snapshotting
    case cloning
    case restoring
    case installing
    case forceStopping
    case initialBoot
    case error
    case preparing

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "State")

    static let caseDisplayRepresentations: [VMState: DisplayRepresentation] = [
        .stopped: "Stopped",
        .starting: "Starting",
        .running: "Running",
        .paused: "Paused",
        .suspended: "Suspended",
        .saving: "Suspending",
        .snapshotting: "Taking Snapshot",
        .cloning: "Cloning",
        .restoring: "Restoring",
        .installing: "Installing",
        .forceStopping: "Force Stopping",
        .initialBoot: "Initial Boot",
        .error: "Error",
        .preparing: "Preparing",
    ]

    /// The case naming `status`.
    init(_ status: VMReportedStatus) {
        self =
            switch status {
            case .runtime(.stopped): .stopped
            case .runtime(.starting): .starting
            case .runtime(.running): .running
            case .runtime(.paused): .paused
            case .runtime(.suspended): .suspended
            case .runtime(.saving): .saving
            case .runtime(.snapshotting): .snapshotting
            case .runtime(.cloning): .cloning
            case .runtime(.restoring): .restoring
            case .runtime(.installing): .installing
            case .runtime(.forceStopping): .forceStopping
            case .runtime(.initialBoot): .initialBoot
            case .runtime(.error): .error
            case .preparing: .preparing
            }
    }
}

/// A guest agent's ``VMAgentStatus``, titled as ``VMAgentStatus/title`` reads
/// it.
enum VMGuestAgentStatus: String, AppEnum {
    case waiting
    case current
    case connected
    case outdated
    case reinstallNeeded
    case updating
    case unresponsive
    case expectedMissing
    case connecting
    case disconnected

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Guest Agent Status")

    static let caseDisplayRepresentations: [VMGuestAgentStatus: DisplayRepresentation] = [
        .waiting: "Set up the Kernova guest agent",
        .current: "Guest agent up to date",
        .connected: "Guest agent connected",
        .outdated: "Update available",
        .reinstallNeeded: "Guest agent can’t update in place",
        .updating: "Updating guest agent",
        .unresponsive: "Guest agent unresponsive",
        .expectedMissing: "Guest agent didn’t reconnect",
        .connecting: "Connecting to guest agent",
        .disconnected: "Guest agent disconnected",
    ]

    /// The status this case names.
    var agentStatus: VMAgentStatus {
        switch self {
        case .waiting: .waiting
        case .current: .current
        case .connected: .connected
        case .outdated: .outdated
        case .reinstallNeeded: .reinstallNeeded
        case .updating: .updating
        case .unresponsive: .unresponsive
        case .expectedMissing: .expectedMissing
        case .connecting: .connecting
        case .disconnected: .disconnected
        }
    }

    /// The case naming `status`.
    init(_ status: VMAgentStatus) {
        self =
            switch status {
            case .waiting: .waiting
            case .current: .current
            case .connected: .connected
            case .outdated: .outdated
            case .reinstallNeeded: .reinstallNeeded
            case .updating: .updating
            case .unresponsive: .unresponsive
            case .expectedMissing: .expectedMissing
            case .connecting: .connecting
            case .disconnected: .disconnected
            }
    }
}

/// A VM's ``VMStateBucket``, titled as ``VMStateBucket/displayName`` reads it.
enum VMStateGroup: String, AppEnum {
    case running
    case suspended
    case stopped
    case heldByAnotherCopy
    case preparing

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "State Group")

    static let caseDisplayRepresentations: [VMStateGroup: DisplayRepresentation] = [
        .running: "Running",
        .suspended: "Suspended",
        .stopped: "Stopped",
        .heldByAnotherCopy: "In use by another copy of Kernova",
        .preparing: "Preparing",
    ]

    /// The bucket this case names.
    var bucket: VMStateBucket {
        switch self {
        case .running: .running
        case .suspended: .suspended
        case .stopped: .stopped
        case .heldByAnotherCopy: .heldByAnotherCopy
        case .preparing: .preparing
        }
    }

    /// The case naming `bucket`.
    init(_ bucket: VMStateBucket) {
        self =
            switch bucket {
            case .running: .running
            case .suspended: .suspended
            case .stopped: .stopped
            case .heldByAnotherCopy: .heldByAnotherCopy
            case .preparing: .preparing
            }
    }
}

/// A VM's ``VMGuestOS``, titled as ``VMGuestOS/displayName`` reads it.
enum VMGuestOperatingSystem: String, AppEnum {
    case macOS
    case linux

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Guest Operating System")

    static let caseDisplayRepresentations: [VMGuestOperatingSystem: DisplayRepresentation] = [
        .macOS: "macOS",
        .linux: "Linux",
    ]

    /// The guest this case names.
    var os: VMGuestOS {
        switch self {
        case .macOS: .macOS
        case .linux: .linux
        }
    }

    /// The case naming `os`.
    init(_ os: VMGuestOS) {
        self =
            switch os {
            case .macOS: .macOS
            case .linux: .linux
            }
    }
}

/// A VM's ``VMNetworkMode``, titled as ``VMNetworkMode/title`` reads it.
enum VMNetworkModeOption: String, AppEnum {
    case nat
    case bridged
    case hostOnly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Network Mode")

    static let caseDisplayRepresentations: [VMNetworkModeOption: DisplayRepresentation] = [
        .nat: "NAT",
        .bridged: "Bridged",
        .hostOnly: "Host Only",
    ]

    /// The case naming `mode`.
    init(_ mode: VMNetworkMode) {
        self =
            switch mode {
            case .nat: .nat
            case .bridged: .bridged
            case .hostOnly: .hostOnly
            }
    }
}

/// A VM's ``VMGuestAgentBucket``, titled as ``VMGuestAgentBucket/displayName``
/// reads it.
enum VMGuestAgentVersion: String, AppEnum {
    case upToDate
    case olderVersion
    case neverConnected

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Guest Agent Version")

    static let caseDisplayRepresentations: [VMGuestAgentVersion: DisplayRepresentation] = [
        .upToDate: "Up to Date",
        .olderVersion: "Older Version",
        .neverConnected: "Never Connected",
    ]

    /// The bucket this case names.
    var bucket: VMGuestAgentBucket {
        switch self {
        case .upToDate: .upToDate
        case .olderVersion: .olderVersion
        case .neverConnected: .neverConnected
        }
    }

    /// The case naming `bucket`.
    init(_ bucket: VMGuestAgentBucket) {
        self =
            switch bucket {
            case .upToDate: .upToDate
            case .olderVersion: .olderVersion
            case .neverConnected: .neverConnected
            }
    }
}
