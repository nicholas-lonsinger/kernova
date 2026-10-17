import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("VirtualizationPlatformFiles Tests", .caseScoped)
struct VirtualizationPlatformFilesTests {
    private let scratch = TestScratchDirectory(prefix: "PlatformFilesTests")

    private func makeBundle() throws -> VMBundleLayout {
        let bundleURL = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return VMBundleLayout(bundleURL: bundleURL)
    }

    @Test("The EFI variable store is created when absent and kept when present")
    func ensureEFIVariableStoreCreatesOnce() throws {
        let layout = try makeBundle()
        let platform = VirtualizationPlatformFiles()
        let url = layout.efiVariableStoreURL

        try platform.ensureEFIVariableStore(bundleURL: layout.bundleURL)
        let created = try Data(contentsOf: url)
        #expect(!created.isEmpty)

        try Data("guest-written".utf8).write(to: url)
        try platform.ensureEFIVariableStore(bundleURL: layout.bundleURL)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "guest-written")
    }

    @Test("Platform files for a hardware model that does not decode write nothing")
    func macPlatformFilesRefuseAnUndecodableModel() throws {
        let layout = try makeBundle()

        #expect(throws: ConfigurationBuilderError.self) {
            _ = try VirtualizationPlatformFiles().createMacPlatformFiles(
                bundleURL: layout.bundleURL, hardwareModel: Data("not a model".utf8))
        }

        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: layout.hardwareModelURL.path(percentEncoded: false)))
        #expect(!manager.fileExists(atPath: layout.machineIdentifierURL.path(percentEncoded: false)))
        #expect(!manager.fileExists(atPath: layout.auxiliaryStorageURL.path(percentEncoded: false)))
    }
}
