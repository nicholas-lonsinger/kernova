import Foundation

/// The `usb-accessories.json` file inside a VM bundle: which host USB
/// accessories that VM takes back automatically.
///
/// `VMBundleLayout` owns the name; this owns the file operations.
protocol USBAccessoryPairingStoring: Sendable {
    /// Reads the set, answering an empty one for a bundle that holds no
    /// pairings — and for one whose file cannot be read, which it removes: a
    /// pairing is made again by attaching the device once.
    func load(bundleURL: URL) -> USBAccessoryPairingSet

    func save(_ pairings: USBAccessoryPairingSet, bundleURL: URL) throws
}
