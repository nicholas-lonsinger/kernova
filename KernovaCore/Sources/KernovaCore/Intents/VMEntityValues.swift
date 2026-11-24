import AppIntents
import Foundation
import KernovaCommandModel

// The pickers a Virtual Machine's closed-set properties are shown and found
// by. Each mirrors a library type for the reason ``VMStopMethod`` states, its
// `init(_:)` exhaustive over that type, and titles each case in the words the
// app gives that value. Those words are spelled out again here because the
// metadata processor takes only a string literal as a case's title: one read
// from the library type fails the build with "Unsupported value for
// interpolated string segment: runtimeValue" (Xcode 27B52).

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
