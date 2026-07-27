import Foundation

extension ProcessInfo {
    /// `true` when the process is running as an XCTest host — the test bundle sets
    /// `XCTestConfigurationFilePath` in the environment.
    ///
    /// The single source of truth for suppressing resident-app / File Provider side
    /// effects under `xcodebuild test` (registering a login item, standing up a File
    /// Provider domain, switching activation policy).
    var isRunningXCTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
