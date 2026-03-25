import Foundation
@testable import Kernova

/// In-memory mock for `VMStorageProviding` that tracks operations without touching disk.
final class MockVMStorageService: VMStorageProviding, @unchecked Sendable {

    // MARK: - Storage

    var bundles: [URL: VMConfiguration] = [:]
    private let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MockVMs", isDirectory: true)

    // MARK: - Call Tracking

    var saveConfigurationCallCount = 0
    var deleteVMBundleCallCount = 0
    var createVMBundleCallCount = 0
    var cloneVMBundleCallCount = 0

    // MARK: - Error Injection

    var createVMBundleError: (any Error)?
    var cloneVMBundleError: (any Error)?
    var saveConfigurationError: (any Error)?
    var deleteVMBundleError: (any Error)?
    /// Set of bundle URLs whose loadConfiguration should throw.
    var loadConfigurationFailURLs: Set<URL> = []

    // MARK: - VMStorageProviding

    var vmsDirectory: URL {
        get throws { baseDirectory }
    }

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        baseDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMStorageService.bundleExtension)",
            isDirectory: true
        )
    }

    func listVMBundles() throws -> [URL] {
        Array(bundles.keys)
    }

    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration {
        if loadConfigurationFailURLs.contains(bundleURL) {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        guard let config = bundles[bundleURL] else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        return config
    }

    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws {
        saveConfigurationCallCount += 1
        if let error = saveConfigurationError { throw error }
        bundles[bundleURL] = configuration
    }

    func createVMBundle(for configuration: VMConfiguration) throws -> URL {
        createVMBundleCallCount += 1
        if let error = createVMBundleError { throw error }
        let url = try bundleURL(for: configuration)
        bundles[url] = configuration
        return url
    }

    func cloneVMBundle(from sourceBundleURL: URL, newConfiguration: VMConfiguration, filesToCopy: [String]) throws -> URL {
        cloneVMBundleCallCount += 1
        if let error = cloneVMBundleError { throw error }
        let url = try bundleURL(for: newConfiguration)
        bundles[url] = newConfiguration
        return url
    }

    func deleteVMBundle(at bundleURL: URL) throws {
        deleteVMBundleCallCount += 1
        if let error = deleteVMBundleError { throw error }
        bundles.removeValue(forKey: bundleURL)
    }

}
