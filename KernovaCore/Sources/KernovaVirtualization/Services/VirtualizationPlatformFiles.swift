import Foundation
import KernovaCore
import KernovaLogging
import Virtualization

/// The firmware and platform files of a VM bundle, as Virtualization writes
/// them.
package struct VirtualizationPlatformFiles: VMPlatformFileWriting {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMBundleMachineFiles")

    package init() {}

    package func ensureEFIVariableStore(bundleURL: URL) throws {
        let url = VMBundleLayout(bundleURL: bundleURL).efiVariableStoreURL
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        _ = try VZEFIVariableStore(creatingVariableStoreAt: url, options: [])
        #log(
            Self.logger, .notice,
            "Created the EFI variable store in '\(bundleURL.lastPathComponent, privacy: .public)'")
    }

    package func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        guard let model = VZMacHardwareModel(dataRepresentation: hardwareModel) else {
            throw ConfigurationBuilderError.invalidHardwareModel
        }
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let manager = FileManager.default
        if !manager.fileExists(atPath: layout.hardwareModelURL.path(percentEncoded: false)) {
            try hardwareModel.write(to: layout.hardwareModelURL)
        }
        if !manager.fileExists(atPath: layout.machineIdentifierURL.path(percentEncoded: false)) {
            try VZMacMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifierURL)
        }
        // Without `.allowOverwrite`, a second Start after an install that got past
        // setup but didn't finish throws "File exists" before the installer runs.
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: layout.auxiliaryStorageURL, hardwareModel: model,
            options: [.allowOverwrite])
        #log(
            Self.logger, .info,
            "Created platform files in '\(bundleURL.lastPathComponent, privacy: .public)'")
        return try Data(contentsOf: layout.machineIdentifierURL)
    }
}
