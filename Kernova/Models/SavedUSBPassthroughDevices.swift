import Darwin
import Foundation
import KernovaLogging

/// The USB passthrough devices one saved state holds, kept on the save file
/// as an extended attribute, so it goes wherever the file is copied, moved or
/// cloned and is deleted with it.
///
/// Trusted only while ``stateFile`` matches the file it is on:
/// `FileManager.replaceItemAt` carries the replaced file's extended
/// attributes onto its replacement, and a restore that configures a device
/// its state lacks fails
/// (`docs/research/2026-10-02-vz-restore-matches-usb-passthrough-devices.md`).
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

    /// Size and modification time, which a write of new state moves and a
    /// copy of the file keeps.
    struct FileStamp: Codable, Sendable, Equatable {
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        /// The stamp of the file at `url`, or `nil` when it cannot be read.
        init?(of url: URL) {
            var info = stat()
            guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    let devices: [Device]
    /// The save file this record describes.
    let stateFile: FileStamp

    private static let attributeName = "app.kernova.usb-passthrough-devices"
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "SavedUSBPassthroughDevices")

    /// Records `attached` on the save file at `url`, which has just been
    /// written holding them.
    static func record(_ attached: [AttachedUSBAccessory], onSaveFileAt url: URL) throws {
        guard let stamp = FileStamp(of: url) else { throw POSIXError(.ENOENT) }
        let data = try JSONEncoder().encode(
            SavedUSBPassthroughDevices(devices: attached.map(Device.init), stateFile: stamp))
        let result = data.withUnsafeBytes {
            setxattr(
                url.path(percentEncoded: false), attributeName, $0.baseAddress, $0.count, 0,
                XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The devices the save file at `url` holds, empty when it carries no
    /// record or one this file does not answer to.
    static func devices(onSaveFileAt url: URL) -> [Device] {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { return [] }
        let record: SavedUSBPassthroughDevices
        do {
            record = try JSONDecoder().decode(SavedUSBPassthroughDevices.self, from: data)
        } catch {
            #log(
                logger, .warning,
                "Ignoring the USB passthrough record on '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
        guard record.stateFile == FileStamp(of: url) else {
            #log(
                logger, .notice,
                "Ignoring the USB passthrough record on '\(url.lastPathComponent, privacy: .public)': it describes an earlier saved state"
            )
            return []
        }
        return record.devices
    }
}
