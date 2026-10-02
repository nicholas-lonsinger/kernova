import Darwin
import Foundation
import KernovaLogging

/// The USB passthrough devices one saved state holds, kept on the save file
/// as an extended attribute, so it goes wherever the file is copied, moved or
/// cloned and is deleted with it.
///
/// Every write of a saved state records what it holds, an empty set included:
/// a restore that configures a device its state lacks fails
/// (`docs/research/2026-10-02-vz-restore-matches-usb-passthrough-devices.md`),
/// so no save file may carry a record from an earlier state.
struct SavedUSBPassthroughDevices: Codable, Sendable, Equatable {
    /// One passthrough device the saved state holds.
    struct Device: Codable, Sendable, Equatable {
        /// The `VZUSBDevice.uuid` it carried when the state was written — the
        /// one a restore must configure it under.
        let deviceID: UUID
        /// The serial-number ``USBAccessoryIdentity/key`` of the unit, or `nil`
        /// when nothing names the unit itself.
        ///
        /// VZ checks the `uuid` and nothing about the hardware behind it, so
        /// only a key that follows one unit may hand that `uuid` to an
        /// accessory; a port-keyed one names whatever is in the port.
        let unitKey: String?
        /// What the log calls it.
        let displayName: String

        init(_ attached: AttachedUSBAccessory) {
            deviceID = attached.deviceID
            let identity = attached.accessory.identity
            unitKey = identity?.form == .serialNumber ? identity?.key : nil
            displayName = attached.accessory.displayName
        }
    }

    let devices: [Device]

    private static let attributeName = "app.kernova.usb-passthrough-devices"
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "SavedUSBPassthroughDevices")

    /// Records `attached` on the save file at `url`, which has just been
    /// written holding exactly them — removing any record when it holds none.
    static func record(_ attached: [AttachedUSBAccessory], onSaveFileAt url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard !attached.isEmpty else {
            guard removexattr(path, attributeName, XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let data = try JSONEncoder().encode(
            SavedUSBPassthroughDevices(devices: attached.map(Device.init)))
        let result = data.withUnsafeBytes {
            setxattr(path, attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The devices the save file at `url` holds, empty when it carries no
    /// record or one that does not decode.
    static func devices(onSaveFileAt url: URL) -> [Device] {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { return [] }
        do {
            return try JSONDecoder().decode(SavedUSBPassthroughDevices.self, from: data).devices
        } catch {
            #log(
                logger, .warning,
                "Ignoring the USB passthrough record on '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
