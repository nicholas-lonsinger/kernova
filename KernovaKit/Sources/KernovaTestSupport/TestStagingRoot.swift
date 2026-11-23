import Foundation
import KernovaKit

/// A ``ProcessStagingRoot`` under a parent no other test shares, removed with
/// everything under it when the test case that made it ends.
///
/// A suite holds one as a stored property, so each test gets its own.
public struct TestStagingRoot: Sendable {
    /// The root a test hands to the staging it builds.
    public let root: ProcessStagingRoot

    private let scratch = TestScratchDirectory(prefix: "KernovaTestStaging")

    /// A root under a fresh parent that nothing outside the staging names a file in; touches no disk.
    public init() {
        root = ProcessStagingRoot(parent: scratch.url)
    }
}
