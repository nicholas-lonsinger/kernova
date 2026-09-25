import Foundation
import KernovaKit

/// A ``ProcessStagingRoot`` under a parent no other test shares, removed with
/// everything under it when this object goes away.
///
/// A suite holds one as a stored property, so each test gets its own.
public final class TestStagingRoot: Sendable {
    /// The root a test hands to the staging it builds.
    public let root: ProcessStagingRoot

    /// The parent ``root`` sits under.
    public let parent: URL

    /// A root under a fresh parent; touches no disk.
    public init() {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaTestStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = ProcessStagingRoot(parent: parent)
    }

    deinit {
        try? FileManager.default.removeItem(at: parent)
    }

    /// Another root under the same parent, standing in for another process's.
    public func makeSibling() -> ProcessStagingRoot {
        ProcessStagingRoot(parent: parent)
    }
}
