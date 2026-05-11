import Foundation

/// Abstraction for VM bundle storage operations, enabling dependency injection and testing.
protocol VMStorageProviding: Sendable {
    var vmsDirectory: URL { get throws }
    func bundleURL(for configuration: VMConfiguration) throws -> URL
    func listVMBundles() throws -> [URL]
    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration
    /// Variant of `loadConfiguration` that lets the caller observe whether
    /// the decode back-filled a missing `discImageDeviceUUID` for a legacy
    /// config. The caller is responsible for persisting the migrated value
    /// (e.g. by calling `saveConfiguration`) so the load itself stays
    /// side-effect-free.
    func loadConfiguration(
        from bundleURL: URL,
        migrationFlag: VMConfiguration.LegacyMigrationFlag
    ) throws -> VMConfiguration
    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws
    func createVMBundle(for configuration: VMConfiguration) throws -> URL
    func deleteVMBundle(at bundleURL: URL) throws
    func cloneVMBundle(from sourceBundleURL: URL, newConfiguration: VMConfiguration, filesToCopy: [String]) throws
        -> URL
}
