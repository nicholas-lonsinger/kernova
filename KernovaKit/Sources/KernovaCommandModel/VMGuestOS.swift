import Foundation

/// The guest operating system type for a virtual machine.
public enum VMGuestOS: String, Codable, CaseIterable, Sendable {
    case macOS
    case linux

    /// What a person reads for this guest.
    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }
}
