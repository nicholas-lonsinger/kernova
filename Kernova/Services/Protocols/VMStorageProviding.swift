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
    /// The identity of the bundle — a directory holding a configuration — at
    /// `bundleURL`, or `nil` when none is there.
    func bundleIdentity(at bundleURL: URL) -> VMBundleIdentity?
    /// Removes a staged tree outright.
    func discardStagedBundle(at stagedURL: URL) throws
    @discardableResult
    func reclaimStagedBundles() -> Task<Void, Never>
    func deleteVMBundle(at bundleURL: URL) throws
    func permanentlyDeleteVMBundle(at bundleURL: URL) throws
    func cloneVMBundle(from sourceBundleURL: URL, to destinationBundleURL: URL, filesToCopy: [String])
        throws
}
