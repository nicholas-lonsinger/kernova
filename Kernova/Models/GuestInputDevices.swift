import Foundation

/// The single pointing/keyboard device pair a macOS guest's configuration
/// carries.
///
/// Exactly one pair is ever attached: a macOS guest that merely *sees* the USB
/// pointing device — bound or not, and regardless of array order — treats it
/// as a mouse and pins its scrollbars always-visible via the default
/// "Automatically based on mouse or trackpad" setting (observed on a macOS 26
/// guest, 2026-08-12/13). A 13+ guest binds the Mac devices and an earlier
/// guest recognizes only the USB pair (`VZMacTrackpadConfiguration.h`,
/// `VZMacKeyboardConfiguration.h`).
enum GuestInputDevices: Equatable, Sendable {
    /// The Mac trackpad and keyboard, for a guest running macOS 13+.
    case mac
    /// The USB pointer and keyboard, for an earlier guest.
    case usb

    /// The first macOS release whose guests bind the Mac-specific input
    /// devices (`VZMacTrackpadConfiguration.h`).
    static let macInputFloor = MacOSVersion(major: 13, minor: 0)

    /// The device pair the macOS guest described by `config` carries.
    ///
    /// An explicit ``VMConfiguration/inputDeviceMode`` choice wins; automatic
    /// resolves from the guest's effective macOS version, and a guest with no
    /// version signal takes the Mac pair — pre-13 guests are the exception,
    /// and the explicit setting covers one arriving with no version record.
    static func resolve(for config: VMConfiguration) -> GuestInputDevices {
        switch config.inputDeviceMode {
        case .mac: return .mac
        case .usb: return .usb
        case .automatic:
            guard let version = config.effectiveGuestMacOSVersion else { return .mac }
            return version.isAtLeast(macInputFloor) ? .mac : .usb
        }
    }
}
