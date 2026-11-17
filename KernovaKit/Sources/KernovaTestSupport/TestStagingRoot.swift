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

    /// Fires once each removal ``root``'s retirement handed back has run; await it instead of polling.
    public var removals: AsyncGate { retirement?.changed ?? AsyncGate() }

    private let scratch = TestScratchDirectory(prefix: "KernovaTestStaging")
    private let retirement: ObservedRetirement?

    /// A root under a fresh parent whose removals happen at once; touches no disk.
    public init() {
        root = ProcessStagingRoot(parent: scratch.url)
        retirement = nil
    }

    /// A root under a fresh parent whose removals go through `retirement`, each one firing ``removals`` once it
    /// ran; touches no disk.
    public init(retirement: some StagedContentRetirement) {
        let observed = ObservedRetirement(retirement)
        root = ProcessStagingRoot(parent: scratch.url, retirement: observed)
        self.retirement = observed
    }

    /// Another root under the same parent, standing in for another process's, its removals going through
    /// `retirement` when given.
    public func makeSibling(retirement: (any StagedContentRetirement)? = nil) -> ProcessStagingRoot {
        ProcessStagingRoot(parent: parent, retirement: retirement)
    }
}

/// A retirement handing everything to another, announcing each removal once it ran.
private final class ObservedRetirement: StagedContentRetirement {
    let changed = AsyncGate()
    private let inner: any StagedContentRetirement

    init(_ inner: any StagedContentRetirement) {
        self.inner = inner
    }

    func retire(_ directories: [URL], then remove: @escaping @Sendable () -> Void) {
        inner.retire(directories) { [self] in
            remove()
            changed.notify()
        }
    }

    func retireAbandoned(_ roots: [URL], then remove: @escaping @Sendable () -> Void) {
        inner.retireAbandoned(roots) { [self] in
            remove()
            changed.notify()
        }
    }

    @MainActor func processEnding(_ root: URL) {
        inner.processEnding(root)
    }
}
