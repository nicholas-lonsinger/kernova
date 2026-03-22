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

    var defaultDiskSizeInGB: Int {
        switch self {
        case .macOS: 100
        case .linux: 50
        }
    }

    /// The fixed disk sizes available for this guest OS, matching bundled ASIF templates.
    var availableDiskSizes: [Int] {
        DiskImageService.templateSizes.filter { $0 >= minDiskSizeInGB }
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
        case .linux: 25
        }
    }

    var maxDiskSizeInGB: Int { 4000 }
}
