import Foundation
import os

/// Discovers and opens the SPICE agent serial device inside a macOS guest VM.
///
/// The host creates a `VZVirtioConsoleDeviceConfiguration` with a port named
/// `com.redhat.spice.0`. Inside the guest this appears as a character device
/// under `/dev/`. This enum scans known candidate paths and opens the first match.
enum SerialPortDiscovery {

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "SerialPortDiscovery")

    /// Device path for the SPICE agent console port.
    /// The host names the port `VZSpiceAgentPortAttachment.spiceAgentPortName`
    /// ("com.redhat.spice.0"); the guest kernel exposes it as `/dev/cu.<name>`.
    private static let devicePath = "/dev/cu.com.redhat.spice.0"

    // RATIONALE: nonisolated(unsafe) is safe here because openDevice() is only called
    // from the main dispatch queue in main.swift's connection retry loop.
    nonisolated(unsafe) private static var hasLoggedDevices = false

    /// Discovers and opens the SPICE agent serial device.
    ///
    /// Scans candidate paths, opens the first matching device with `O_RDWR | O_NOCTTY | O_NONBLOCK`,
    /// and returns a `FileHandle` for bidirectional communication.
    ///
    /// - Returns: A `FileHandle` wrapping the opened device, or `nil` if no device was found.
    static func openDevice() -> FileHandle? {
        if !hasLoggedDevices {
            logAvailableSerialDevices()
            hasLoggedDevices = true
        }

        let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            logger.debug("SPICE device not available at '\(devicePath, privacy: .public)'")
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
