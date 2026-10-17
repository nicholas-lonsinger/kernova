import Foundation

@testable import KernovaCore

/// A `VMPlatformFileWriting` that writes stand-ins where Virtualization would
/// write the firmware and platform files: the files exist, under the names the
/// bundle reads them by, and hold nothing Virtualization could open.
package struct FakePlatformFiles: VMPlatformFileWriting {
    package init() {}

    package func ensureEFIVariableStore(bundleURL: URL) throws {
        let url = VMBundleLayout(bundleURL: bundleURL).efiVariableStoreURL
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try Data().write(to: url)
    }

    /// Writes `hardwareModel` and a fresh machine identifier where none is,
    /// and an empty auxiliary storage over any there.
    package func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let manager = FileManager.default
        if !manager.fileExists(atPath: layout.hardwareModelURL.path(percentEncoded: false)) {
            try hardwareModel.write(to: layout.hardwareModelURL)
        }
        if !manager.fileExists(atPath: layout.machineIdentifierURL.path(percentEncoded: false)) {
            try FakeVirtualizationHost().makeMacMachineIdentifier().write(to: layout.machineIdentifierURL)
        }
        try Data().write(to: layout.auxiliaryStorageURL)
        return try Data(contentsOf: layout.machineIdentifierURL)
    }
}
