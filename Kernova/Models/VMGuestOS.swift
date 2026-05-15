import Foundation

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
        return min(preferred, maxCPUCount)
    }

    var defaultMemoryInGB: Int {
        let preferred: Int
        switch self {
        case .macOS: preferred = 8
        case .linux: preferred = 4
        }
        return min(preferred, maxMemoryInGB)
    }

    /// Default size used when creating a new disk image.
    ///
    /// OS-independent — fits comfortably above both guest OSes'
    /// `minDiskSizeInGB` and is present in `allDiskSizes`.
    static let defaultDiskSizeInGB = 100

    /// All offered disk sizes in GB, matching bundled ASIF templates.
    static let allDiskSizes = [
        10, 15, 20, 25, 50, 75, 100, 150, 200, 250,
        500, 750, 1000, 1500, 2000, 2500, 5000, 7500, 10000,
    ]

    /// The disk sizes available for this guest OS, filtered by minimum.
    var availableDiskSizes: [Int] {
        Self.allDiskSizes.filter { $0 >= minDiskSizeInGB }
    }

    var minCPUCount: Int { 2 }

    var maxCPUCount: Int {
        ProcessInfo.processInfo.processorCount
    }

    var minMemoryInGB: Int {
        switch self {
        case .macOS: 4
        case .linux: 2
        }
    }

    var maxMemoryInGB: Int {
        let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        return Int(totalMemoryBytes / (1024 * 1024 * 1024))
    }

    var minDiskSizeInGB: Int {
        switch self {
        case .macOS: 64
        case .linux: 10
        }
    }
}
