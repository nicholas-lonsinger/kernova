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

    /// A root under a fresh parent that nothing outside the staging names a file in; touches no disk.
    public init() {
        root = ProcessStagingRoot(parent: scratch.url)
    }

    /// A root under a fresh parent whose process end and reclaim go through `retirement`; touches no disk.
    public init(retirement: some StagedContentRetirement) {
        root = ProcessStagingRoot(parent: scratch.url, retirement: retirement)
    }

    /// Another root under the same parent, standing in for another process's, its reclaim going through
    /// `retirement` when given.
    public func makeSibling(retirement: (any StagedContentRetirement)? = nil) -> ProcessStagingRoot {
        ProcessStagingRoot(parent: parent, retirement: retirement)
    }
}
