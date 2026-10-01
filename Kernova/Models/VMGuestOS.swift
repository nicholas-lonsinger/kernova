import Foundation
import KernovaKit

/// The guest operating system type for a virtual machine.
enum VMGuestOS: String, Codable, CaseIterable, Sendable {
    case macOS
    case linux

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }

    var iconName: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        }
    }

    var defaultCPUCount: Int {
        let preferred: Int
        switch self {
        case .macOS: preferred = 4
        case .linux: preferred = 2
        }
        return VMResourceLimits.cpuCount.clamp(preferred)
    }

    var defaultMemorySize: VMMemorySize {
        let preferred: VMMemorySize
        switch self {
        case .macOS: preferred = .gibibytes(8)
        case .linux: preferred = .gibibytes(4)
        }
        return VMResourceLimits.memorySize.clamp(preferred)
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
}
