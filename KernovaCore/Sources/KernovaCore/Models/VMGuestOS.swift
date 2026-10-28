import Foundation
import KernovaCommandModel

/// One row of the Guest Agent settings section: a setting that rides the
/// Kernova guest agent.
package enum GuestAgentSetting: Sendable, Equatable {
    /// "Forward guest logs": `agentLogForwardingEnabled`.
    case forwardLogs
    /// "Clipboard sharing", where it rides the agent's channel
    /// (``VMGuestOS/sharesClipboardThroughDevice`` false); a guest whose
    /// clipboard rides a device shows it in a Clipboard section of its own.
    case clipboard
    /// "Drag and drop files": `dropFilesEnabled`.
    case dropFiles
    /// "Show install reminder": the host state's install nudge.
    case installReminder
}

extension VMGuestOS {
    package var iconName: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        }
    }

    /// The CPU count a new guest of this OS gets on a host bounded by `limits`.
    func defaultCPUCount(within limits: VMResourceLimits) -> Int {
        let preferred: Int
        switch self {
        case .macOS: preferred = 4
        case .linux: preferred = 2
        }
        return limits.cpuCount.clamp(preferred)
    }

    /// The memory a new guest of this OS gets on a host bounded by `limits`.
    func defaultMemorySize(within limits: VMResourceLimits) -> VMMemorySize {
        let preferred: VMMemorySize
        switch self {
        case .macOS: preferred = .gibibytes(8)
        case .linux: preferred = .gibibytes(4)
        }
        return limits.memorySize.clamp(preferred)
    }

    /// Default size used when creating a new disk image; one of `allDiskSizes`.
    package static let defaultDiskSizeInGB = 100

    /// Every disk size offered, in GB, matching the bundled ASIF templates.
    package static let allDiskSizes = [
        10, 15, 20, 25, 50, 75, 100, 150, 200, 250,
        500, 750, 1000, 1500, 2000, 2500, 5000, 7500, 10000,
    ]

    /// Whether the guest's display scanout carries a pixel density, so a HiDPI
    /// resolution reads as Retina rather than as twice as many pixels.
    ///
    /// A virtio scanout has no density channel, so a Linux guest renders 2×
    /// pixels at half the size with nothing to compensate: its resolution must
    /// never be rewritten for HiDPI, and it is offered no HiDPI control.
    package var supportsDisplayDensity: Bool {
        switch self {
        case .macOS: true
        case .linux: false
        }
    }

    /// Whether clipboard sharing reaches the guest through a device the
    /// machine is built with — a Linux guest's SPICE console port — rather
    /// than over the guest agent's channel, so turning it on or off changes
    /// the machine.
    package var sharesClipboardThroughDevice: Bool {
        switch self {
        case .macOS: false
        case .linux: true
        }
    }

    /// The guest-agent settings this guest's agent offers, in the order the
    /// Guest Agent section shows them; each setting's configuration key
    /// applies exactly where it is listed.
    package var guestAgentSettings: [GuestAgentSetting] {
        switch self {
        case .macOS: [.forwardLogs, .clipboard, .dropFiles, .installReminder]
        case .linux: [.forwardLogs]
        }
    }

    /// Whether every shared directory rides one directory-sharing device — a
    /// macOS guest's automount device — rather than a device each, so the
    /// shares can change while at least one remains without changing the
    /// machine's devices.
    package var sharesDirectoriesThroughOneDevice: Bool {
        switch self {
        case .macOS: true
        case .linux: false
        }
    }
}
