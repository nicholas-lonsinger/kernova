import Foundation

/// Abstraction for VM bundle storage operations, enabling dependency injection and testing.
protocol VMStorageProviding: Sendable {
    var vmsDirectory: URL { get throws }
    /// What every bundle's state files are read and written through.
    var bundleFiles: any VMBundleFileAccessing { get }
    func bundleURL(for configuration: VMConfiguration) throws -> URL
    func makeStagedBundleURL() throws -> URL
    func listVMBundles() throws -> [URL]
    func createVMBundle(at bundleURL: URL) throws
    func publishBundle(from stagedURL: URL, to bundleURL: URL) throws
    /// Whether a bundle — a directory holding a configuration — is at `bundleURL`.
    func bundleExists(at bundleURL: URL) -> Bool
    /// Removes a staged tree outright.
    func discardStagedBundle(at stagedURL: URL) throws
    @discardableResult
    func reclaimStagedBundles() -> Task<Void, Never>
    func deleteVMBundle(at bundleURL: URL) throws
    func permanentlyDeleteVMBundle(at bundleURL: URL) throws
    func cloneVMBundle(from sourceBundleURL: URL, to destinationBundleURL: URL, filesToCopy: [String])
        throws
}
