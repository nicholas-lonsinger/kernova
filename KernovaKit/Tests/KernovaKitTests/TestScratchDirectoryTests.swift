import Foundation
import Testing

@testable import KernovaTestSupport

/// A scratch directory's removal is owed to the test case that minted it, not
/// to the lifetime of whatever holds the value.
@Suite("TestScratchDirectory", .caseScoped)
struct TestScratchDirectoryTests {
    private let scratch = TestScratchDirectory(prefix: "ScratchLedgerTests")

    /// Stands in for a suite instance: a scratch held as a stored property.
    private struct Holder {
        let scratch = TestScratchDirectory(prefix: "ScratchLedgerHolder")
    }

    @Test("a suite's stored-property scratch is recorded with the case's ledger")
    func storedPropertyRegistersWithTheCaseLedger() throws {
        let ledger = try #require(TestScratchLedger.current)
        #expect(ledger.recordedURLs.contains(scratch.url))
    }

    @Test("a scope removes a stored-property scratch when it ends, while its holder is still alive")
    func scopeRemovesAStoredPropertyScratchItsHolderOutlives() async throws {
        let outer = try #require(TestScratchLedger.current)
        let holder = try await TestScratchLedger.scoping {
            let holder = Holder()
            try FileManager.default.createDirectory(at: holder.scratch.url, withIntermediateDirectories: true)
            return holder
        }

        #expect(!FileManager.default.fileExists(atPath: holder.scratch.url.path))
        #expect(!outer.recordedURLs.contains(holder.scratch.url))
    }

    @Test("a scope removes its scratch when its body throws")
    func scopeRemovesScratchWhenItsBodyThrows() async throws {
        struct Failure: Error {}
        var minted: URL?
        await #expect(throws: Failure.self) {
            try await TestScratchLedger.scoping {
                let scratch = TestScratchDirectory(prefix: "ScratchLedgerThrow")
                minted = scratch.url
                try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
                throw Failure()
            }
        }

        let url = try #require(minted)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("forCase names one directory per prefix within a case, recorded once")
    func forCaseIsMemoizedPerPrefix() throws {
        let ledger = try #require(TestScratchLedger.current)
        let first = TestScratchDirectory.forCase(prefix: "ScratchLedgerShared")
        let again = TestScratchDirectory.forCase(prefix: "ScratchLedgerShared")
        let other = TestScratchDirectory.forCase(prefix: "ScratchLedgerOther")

        #expect(first.url == again.url)
        #expect(first.url != other.url)
        #expect(ledger.recordedURLs.filter { $0 == first.url }.count == 1)
    }

    @Test("a scratch is named under the temporary directory with its symlinks resolved")
    func scratchSitsUnderTheResolvedTemporaryDirectory() {
        let resolved = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        #expect(scratch.url.deletingLastPathComponent().path == resolved.path)
        #expect(scratch.url.lastPathComponent.hasPrefix("ScratchLedgerTests-"))
    }
}
