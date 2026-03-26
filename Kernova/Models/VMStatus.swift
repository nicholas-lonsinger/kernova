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
        case .saving: "Suspending"
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

    /// Overlay label for save/restore transitions, or `nil` for non-transitional states.
    var transitionLabel: String? {
        switch self {
        case .saving: "Suspending…"
        case .restoring: "Restoring…"
        default: nil
        }
    }

    var canStart: Bool { self == .stopped || self == .error }
    /// Status-level stop eligibility. Does not account for cold-paused state;
    /// prefer `VMInstance.canStop` for runtime checks.
    var canStop: Bool { self == .running || self == .paused }
    var canPause: Bool { self == .running }
    var canResume: Bool { self == .paused }
    var canSave: Bool { self == .running || self == .paused }
    var canEditSettings: Bool { self == .stopped || self == .error }

    /// Whether the VM has a live display session that a backing view should present.
    var hasActiveDisplay: Bool {
        switch self {
        case .running, .paused, .saving, .restoring: true
        default: false
        }
    }

    var canForceStop: Bool {
        switch self {
        case .running, .paused, .starting, .saving, .restoring: true
        default: false
        }
    }

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
