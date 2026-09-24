import Foundation
import KernovaLogging

/// Reads and writes the pairings a VM bundle holds.
struct USBAccessoryPairingStore: USBAccessoryPairingStoring {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "USBAccessoryPairingStore")

    func load(bundleURL: URL) -> USBAccessoryPairingSet {
        let url = VMBundleLayout(bundleURL: bundleURL).usbPairingsURL
        do {
            return try VMBundleSidecarFile.read(USBAccessoryPairingSet.self, at: url)
                ?? USBAccessoryPairingSet()
        } catch {
            #log(
                Self.logger, .error,
                "Removing the USB accessory pairings in '\(bundleURL.lastPathComponent, privacy: .public)' because they could not be read: \(error.localizedDescription, privacy: .public)"
            )
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                #log(
                    Self.logger, .error,
                    "Failed to remove the unreadable '\(url.lastPathComponent, privacy: .public)' in '\(bundleURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
            return USBAccessoryPairingSet()
        }
    }

    func save(_ pairings: USBAccessoryPairingSet, bundleURL: URL) throws {
        try VMBundleSidecarFile.write(
            pairings, to: VMBundleLayout(bundleURL: bundleURL).usbPairingsURL)
    }
}
