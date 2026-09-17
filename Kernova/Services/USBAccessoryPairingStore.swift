import Foundation
import KernovaLogging

/// Reads and writes the pairings a VM bundle holds.
struct USBAccessoryPairingStore: USBAccessoryPairingStoring {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "USBAccessoryPairingStore")

    func load(bundleURL: URL) -> USBAccessoryPairingSet {
        let url = VMBundleLayout(bundleURL: bundleURL).usbPairingsURL
        guard let data = try? Data(contentsOf: url) else { return USBAccessoryPairingSet() }
        do {
            return try VMConfiguration.makeJSONDecoder().decode(
                USBAccessoryPairingSet.self, from: data)
        } catch {
            // An unreadable file leaves the VM taking nothing back, which is
            // the state a user recovers from by attaching the device once.
            #log(
                Self.logger, .error,
                "Failed to read the USB accessory pairings in '\(bundleURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return USBAccessoryPairingSet()
        }
    }

    func save(_ pairings: USBAccessoryPairingSet, bundleURL: URL) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let data = try VMConfiguration.makeJSONEncoder().encode(pairings)
        try data.write(to: layout.usbPairingsURL, options: .atomic)
    }
}
