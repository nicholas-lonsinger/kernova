import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// One claim per copy of Kernova: what lets exactly one process of a copy run
/// and bind its socket.
///
/// A second claim from this process is refused exactly as another process's
/// is (`ExclusiveFileLock`), so these run in one process.
@Suite("AppCopyClaim", .caseScoped)
struct AppCopyClaimTests {
    private let scratch = TestScratchDirectory(prefix: "AppCopyClaimTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// A `Kernova.app` directory at `relativePath` under `directory`.
    private func makeBundle(in directory: URL, at relativePath: String = "Kernova.app") throws -> URL {
        let bundle = directory.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    /// The group container the claims lock their files in.
    private func makeContainer(in directory: URL) throws -> URL {
        let container = directory.appendingPathComponent("Container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    private func claim(_ bundle: URL, in container: URL) -> AppCopyClaim? {
        guard case .claimed(let claim) = AppCopyClaim.acquire(forAppBundle: bundle, in: container)
        else { return nil }
        return claim
    }

    private func isAlreadyHeld(_ bundle: URL, in container: URL) -> Bool {
        guard case .alreadyHeld = AppCopyClaim.acquire(forAppBundle: bundle, in: container) else {
            return false
        }
        return true
    }

    @Test("A second claim on one copy is refused while the first is held, and granted after release")
    func secondClaimRefusedUntilReleased() throws {
        let bundle = try makeBundle(in: scratch.url)
        let container = try makeContainer(in: scratch.url)

        do {
            let held = try #require(claim(bundle, in: container))
            #expect(isAlreadyHeld(bundle, in: container))
            withExtendedLifetime(held) {}
        }
        #expect(claim(bundle, in: container) != nil)
    }

    @Test("A claim through a symlink to a claimed copy is refused")
    func symlinkedCopyIsRefused() throws {
        let bundle = try makeBundle(in: scratch.url)
        let container = try makeContainer(in: scratch.url)
        let link = scratch.url.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        let held = try #require(claim(bundle, in: container))
        #expect(isAlreadyHeld(link, in: container))
        withExtendedLifetime(held) {}
    }

    @Test("Another copy claims on its own while one copy is held")
    func distinctCopyClaimsIndependently() throws {
        let installed = try makeBundle(in: scratch.url, at: "Applications/Kernova.app")
        let built = try makeBundle(in: scratch.url, at: "Build/Products/Debug/Kernova.app")
        let container = try makeContainer(in: scratch.url)

        let held = try #require(claim(installed, in: container))
        let other = try #require(claim(built, in: container))
        #expect(held.socketPath != other.socketPath)
        withExtendedLifetime(held) {}
    }

    /// The tool names the socket without a claim; the app binds where its claim
    /// says, and the two must be one path.
    @Test("A claim's socket is the one the tool names for that copy")
    func claimSocketIsTheCopysSocket() throws {
        let bundle = try makeBundle(in: scratch.url)
        let container = try makeContainer(in: scratch.url)

        let held = try #require(claim(bundle, in: container))
        #expect(
            held.socketPath
                == (try KernovaAppGroup.CopyFiles(forAppBundle: bundle, in: container).socketPath))
    }

    @Test("A copy that is not there cannot be claimed")
    func missingCopyIsUnavailable() throws {
        let container = try makeContainer(in: scratch.url)
        let gone = scratch.url.appendingPathComponent("Kernova.app", isDirectory: true)

        guard case .unavailable(let reason) = AppCopyClaim.acquire(forAppBundle: gone, in: container)
        else {
            Issue.record("a missing copy was not reported unavailable")
            return
        }
        #expect(reason == .unnamed(.unresolvableBundle(.noSuchFileOrDirectory)))
    }
}
