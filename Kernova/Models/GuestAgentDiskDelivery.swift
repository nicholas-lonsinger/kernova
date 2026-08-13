import Foundation

/// How the bundled guest-agent installer image reaches a macOS guest.
///
/// A guest below ``usbMassStorageFloor`` enumerates a
/// `VZUSBMassStorageDeviceConfiguration` but binds no driver to it, so the disk
/// never appears in the guest and the USB path delivers nothing.
enum GuestAgentDiskDelivery: Equatable, Sendable {
    /// Hot-plugged onto the XHCI controller on demand, and ejectable while the
    /// VM runs.
    case usb
    /// Attached on `storageDevices` at every boot, for the whole session.
    case virtio

    /// The macOS release where `IOUSBMassStorageDriver.kext` entered the boot
    /// kernel collection, and so the first one whose kernel holds the
    /// personalities that match a VZ USB mass storage device.
    ///
    /// On an earlier guest the kext is present in `/System/Library/Extensions`
    /// but absent from the collection `kmutil inspect` reports, the device stops
    /// at `IOUSBHostInterface`, and `kernelmanagerd` logs no load request
    /// (`docs/research/2026-08-07-macos12-usb-mass-storage.md`). This is a
    /// property of the *guest*, never of the host.
    static let usbMassStorageFloor = MacOSVersion(major: 12, minor: 3)

    /// The bus the guest described by `config` takes the installer image on.
    ///
    /// A guest whose version neither signal answers for gets ``usb``, the
    /// behavior every VM had before this policy existed.
    static func mode(for config: VMConfiguration) -> GuestAgentDiskDelivery {
        // `guestOS`, not `bootMode`: a Linux guest has no Kernova agent at all,
        // and both enums carry a `.macOS` case.
        guard config.guestOS == .macOS else { return .usb }
        guard let version = config.effectiveGuestMacOSVersion else { return .usb }
        return version.isAtLeast(usbMassStorageFloor) ? .usb : .virtio
    }
}
