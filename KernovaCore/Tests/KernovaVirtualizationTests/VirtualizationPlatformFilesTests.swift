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
}
