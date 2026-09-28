import Foundation
import KernovaKit

/// A ``ProcessStagingRoot`` under a parent no other test shares, removed with
/// everything under it when the test case that made it ends.
///
/// A suite holds one as a stored property, so each test gets its own.
public struct TestStagingRoot: Sendable {
    /// The root a test hands to the staging it builds.
    public let root: ProcessStagingRoot

    /// The parent ``root`` sits under.
    public var parent: URL { scratch.url }

    private let scratch = TestScratchDirectory(prefix: "KernovaTestStaging")

    /// A root under a fresh parent; touches no disk.
    public init() {
        root = ProcessStagingRoot(parent: scratch.url)
    }

    /// Another root under the same parent, standing in for another process's.
    public func makeSibling() -> ProcessStagingRoot {
        ProcessStagingRoot(parent: parent)
    }
}
