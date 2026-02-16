import Foundation

/// Abstraction for VM bundle storage operations, enabling dependency injection and testing.
protocol VMStorageProviding: Sendable {
    var vmsDirectory: URL { get throws }
    func bundleURL(for configuration: VMConfiguration) throws -> URL
    func listVMBundles() throws -> [URL]
    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration
    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws
    func createVMBundle(for configuration: VMConfiguration) throws -> URL
    func deleteVMBundle(at bundleURL: URL) throws
    func migrateBundleIfNeeded(at bundleURL: URL) throws -> URL
}
