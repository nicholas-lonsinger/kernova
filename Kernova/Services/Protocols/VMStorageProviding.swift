import Foundation

/// Abstraction for VM bundle storage operations, enabling dependency injection and testing.
protocol VMStorageProviding: Sendable {
    var vmsDirectory: URL { get throws }
    var stagingDirectory: URL { get throws }
    func bundleURL(for configuration: VMConfiguration) throws -> URL
    func stagedBundleURL(for configuration: VMConfiguration) throws -> URL
    func listVMBundles() throws -> [URL]
    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration
    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws
    func createVMBundle(_ configuration: VMConfiguration, at bundleURL: URL) throws
    func publishBundle(from stagedURL: URL, to bundleURL: URL) throws
    func reclaimStagedBundles()
    func deleteVMBundle(at bundleURL: URL) throws
    func permanentlyDeleteVMBundle(at bundleURL: URL) throws
    func cloneVMBundle(
        from sourceBundleURL: URL, to destinationBundleURL: URL, newConfiguration: VMConfiguration,
        filesToCopy: [String]
    ) throws
}
