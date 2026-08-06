import Foundation

/// The boot mode for a virtual machine.
enum VMBootMode: String, Codable, Sendable {
    /// Boot a macOS guest using the macOS boot loader.
    case macOS

    /// Boot a Linux guest using EFI firmware with an ISO image.
    case efi

    /// Boot a Linux guest directly from a kernel image.
    case linuxKernel

    var displayName: String {
        switch self {
        case .macOS: "macOS Boot Loader"
        case .efi: "EFI Boot"
        case .linuxKernel: "Linux Kernel"
        }
    }
}
