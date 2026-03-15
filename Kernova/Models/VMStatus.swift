import Foundation
import SwiftUI

/// The runtime status of a virtual machine.
enum VMStatus: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case restoring
    case installing
    case error

    var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Saving"
        case .restoring: "Restoring"
        case .installing: "Installing"
        case .error: "Error"
        }
    }

    var statusColor: Color {
        switch self {
        case .stopped: .secondary
        case .starting, .saving, .restoring, .installing: .orange
        case .running: .green
        case .paused: .yellow
        case .error: .red
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .saving, .restoring, .installing: true
        default: false
        }
    }

    var canStart: Bool { self == .stopped || self == .error }
    var canStop: Bool { self == .running || self == .paused }
    var canPause: Bool { self == .running }
    var canResume: Bool { self == .paused }
    var canSave: Bool { self == .running || self == .paused }
    var canEditSettings: Bool { self == .stopped || self == .error }

    /// Whether this status represents an active VM that should keep the app alive.
    /// Note: live-paused VMs (`.paused` with a non-nil `VZVirtualMachine`) should
    /// be handled separately by the caller.
    var isActive: Bool {
        switch self {
        case .running, .starting, .saving, .restoring, .installing:
            true
        case .paused, .stopped, .error:
            false
        }
    }
}
