import Foundation
import KernovaKit

extension VMGuestOS {
    var iconName: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        }
    }

    /// The CPU count a new guest of this OS asks for, before a host's bounds
    /// apply.
    var preferredCPUCount: Int {
        switch self {
        case .macOS: 4
        case .linux: 2
        }
    }

    /// The memory a new guest of this OS asks for, before a host's bounds
    /// apply.
    var preferredMemorySize: VMMemorySize {
        switch self {
        case .macOS: .gibibytes(8)
        case .linux: .gibibytes(4)
        }
    }

    /// The CPU count a new guest of this OS gets on a host bounded by `limits`.
    func defaultCPUCount(within limits: VMResourceLimits) -> Int {
        limits.cpuCount.clamp(preferredCPUCount)
    }

    /// The memory a new guest of this OS gets on a host bounded by `limits`.
    func defaultMemorySize(within limits: VMResourceLimits) -> VMMemorySize {
        limits.memorySize.clamp(preferredMemorySize)
    }

    /// Default size used when creating a new disk image; one of `allDiskSizes`.
    static let defaultDiskSizeInGB = 100

    /// Every disk size offered, in GB, matching the bundled ASIF templates.
    static let allDiskSizes = [
        10, 15, 20, 25, 50, 75, 100, 150, 200, 250,
        500, 750, 1000, 1500, 2000, 2500, 5000, 7500, 10000,
    ]

    /// Whether the guest's display scanout carries a pixel density, so a HiDPI
    /// resolution reads as Retina rather than as twice as many pixels.
    ///
    /// A virtio scanout has no density channel, so a Linux guest renders 2×
    /// pixels at half the size with nothing to compensate: its resolution must
    /// never be rewritten for HiDPI, and it is offered no HiDPI control.
    var supportsDisplayDensity: Bool {
        switch self {
        case .macOS: true
        case .linux: false
        }
    }

    /// Whether clipboard sharing reaches the guest through a device the
    /// machine is built with — a Linux guest's SPICE console port — rather
    /// than over the guest agent's channel, so turning it on or off changes
    /// the machine.
    var sharesClipboardThroughDevice: Bool {
        switch self {
        case .macOS: false
        case .linux: true
        }
    }

    /// Whether every shared directory rides one directory-sharing device — a
    /// macOS guest's automount device — rather than a device each, so the
    /// shares can change while at least one remains without changing the
    /// machine's devices.
    var sharesDirectoriesThroughOneDevice: Bool {
        switch self {
        case .macOS: true
        case .linux: false
        }
    }
}
