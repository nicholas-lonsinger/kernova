import Foundation

extension ProcessInfo {
    /// `true` when the process is running as an XCTest host — the test bundle sets
    /// `XCTestConfigurationFilePath` in the environment.
    var isRunningXCTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
