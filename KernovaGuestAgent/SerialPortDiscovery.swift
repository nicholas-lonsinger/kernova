import Foundation
import os

/// Opens the SPICE agent serial device inside a macOS guest VM.
///
/// The host creates a `VZVirtioConsoleDeviceConfiguration` with a port named
/// `com.redhat.spice.0` (via `VZSpiceAgentPortAttachment.spiceAgentPortName`).
/// Inside the guest this appears as a character device at `/dev/cu.<name>`.
enum SerialPortDiscovery {

    private static let logger = KernovaLogger(subsystem: "com.kernova.agent", category: "SerialPortDiscovery")

    /// Device path for the SPICE agent console port.
    /// The host names the port `VZSpiceAgentPortAttachment.spiceAgentPortName`
    /// ("com.redhat.spice.0"); the guest kernel exposes it as `/dev/cu.<name>`.
    private static let devicePath = "/dev/cu.com.redhat.spice.0"

    private static let logOnce: () = {
        logAvailableSerialDevices()
    }()

    /// Attempts to open the SPICE agent serial device at the known path.
    ///
    /// - Returns: A `FileHandle` wrapping the opened device, or `nil` if unavailable.
    static func openDevice() -> FileHandle? {
        _ = logOnce

        let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENXIO {
                logger.debug("SPICE device not available at '\(devicePath, privacy: .public)'")
            } else {
                logger.warning("Failed to open SPICE device at '\(devicePath, privacy: .public)': \(String(cString: strerror(code)), privacy: .public) (errno=\(code, privacy: .public))")
            }
            return nil
        }
        logger.notice("Opened SPICE device at '\(devicePath, privacy: .public)' (fd=\(fd, privacy: .public))")
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Logs all `/dev/cu.*` devices at debug level to aid device path discovery during development.
    private static func logAvailableSerialDevices() {
        do {
            let devContents = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            let serialDevices = devContents.filter { $0.hasPrefix("cu.") }.sorted()
            if serialDevices.isEmpty {
                logger.debug("No /dev/cu.* serial devices found")
            } else {
                logger.debug("Available serial devices: \(serialDevices, privacy: .public)")
            }
        } catch {
            logger.debug("Failed to enumerate /dev: \(error.localizedDescription, privacy: .public)")
        }
    }
}
