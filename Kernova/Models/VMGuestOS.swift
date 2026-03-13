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
        switch self {
        case .macOS: 4
        case .linux: 2
        }
    }

    var defaultMemoryInGB: Int {
        switch self {
        case .macOS: 8
        case .linux: 4
        }
    }

    var defaultDiskSizeInGB: Int {
        switch self {
        case .macOS: 100
        case .linux: 64
        }
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

    var maxDiskSizeInGB: Int { 2048 }
}
