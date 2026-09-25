import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// One claim per copy of Kernova: what lets exactly one process of a copy run
/// and bind its socket.
///
/// A second claim from this process is refused exactly as another process's
/// is (`ExclusiveFileLock`), so these run in one process.
@Suite("AppCopyClaim", .admissionGated)
struct AppCopyClaimTests {
    /// A `Kernova.app` directory at `relativePath` under `scratch`.
    private func makeBundle(in scratch: URL, at relativePath: String = "Kernova.app") throws -> URL {
        let bundle = scratch.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    /// The group container the claims lock their files in.
    private func makeContainer(in scratch: URL) throws -> URL {
        let container = scratch.appendingPathComponent("Container", isDirectory: true)
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
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        let container = try makeContainer(in: scratch)

        do {
            let held = try #require(claim(bundle, in: container))
            #expect(isAlreadyHeld(bundle, in: container))
            withExtendedLifetime(held) {}
        }
        #expect(claim(bundle, in: container) != nil)
    }

    @Test("A claim through a symlink to a claimed copy is refused")
    func symlinkedCopyIsRefused() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        let container = try makeContainer(in: scratch)
        let link = scratch.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        let held = try #require(claim(bundle, in: container))
        #expect(isAlreadyHeld(link, in: container))
        withExtendedLifetime(held) {}
    }

    @Test("Another copy claims on its own while one copy is held")
    func distinctCopyClaimsIndependently() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = try makeBundle(in: scratch, at: "Applications/Kernova.app")
        let built = try makeBundle(in: scratch, at: "Build/Products/Debug/Kernova.app")
        let container = try makeContainer(in: scratch)

        let held = try #require(claim(installed, in: container))
        let other = try #require(claim(built, in: container))
        #expect(held.socketPath != other.socketPath)
        withExtendedLifetime(held) {}
    }

    /// The tool names the socket without a claim; the app binds where its claim
    /// says, and the two must be one path.
    @Test("A claim's socket is the one the tool names for that copy")
    func claimSocketIsTheCopysSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        let container = try makeContainer(in: scratch)

        let held = try #require(claim(bundle, in: container))
        #expect(
            held.socketPath
                == (try KernovaAppGroup.CopyFiles(forAppBundle: bundle, in: container).socketPath))
    }

    @Test("A copy that is not there cannot be claimed")
    func missingCopyIsUnavailable() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let container = try makeContainer(in: scratch)
        let gone = scratch.appendingPathComponent("Kernova.app", isDirectory: true)

        guard case .unavailable(let reason) = AppCopyClaim.acquire(forAppBundle: gone, in: container)
        else {
            Issue.record("a missing copy was not reported unavailable")
            return
        }
        #expect(reason == .unnamed(.unresolvableBundle(.noSuchFileOrDirectory)))
    }
}
