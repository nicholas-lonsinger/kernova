import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The `host-state.json` file: what a round trip preserves, and what a bundle
/// that cannot answer reads as.
@Suite("VMHostState Tests", .admissionGated)
struct VMHostStateTests {
    private let storage = VMStorageService()

    /// A bundle directory of this test's own, removed when it finishes.
    private func withBundle(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-host-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// Every field away from its default, so a field the custom `init(from:)`
    /// misses fails the round trip instead of decoding to the default.
    private func everyFieldSet() -> VMHostState {
        var hostState = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .popOut,
            lastFullscreenDisplayID: 0xDEAD_BEEF, agentInstallNudgeDismissed: true)
        hostState.applyEphemeralMode(
            enabled: true, baseline: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF"))
        return hostState
    }

    @Test("A new VM's host state is the defaults")
    func defaults() {
        let hostState = VMHostState()

        #expect(!hostState.startsAutomaticallyOnLaunch)
        #expect(!hostState.ephemeralModeEnabled)
        #expect(hostState.ephemeralBaselineSnapshotID == nil)
        #expect(hostState.displayPreference == .inline)
        #expect(hostState.lastFullscreenDisplayID == nil)
        #expect(!hostState.agentInstallNudgeDismissed)
    }

    @Test("A written host state reads back as itself")
    func roundTrip() throws {
        try withBundle { bundleURL in
            let written = everyFieldSet()

            try storage.saveHostState(written, to: bundleURL)

            #expect(try storage.loadHostState(from: bundleURL) == written)
        }
    }

    @Test("A bundle with no file holds the defaults")
    func missingFileReadsAsDefaults() throws {
        try withBundle { bundleURL in
            let loaded = try storage.loadHostState(from: bundleURL)
            #expect(loaded == VMHostState())
        }
    }

    @Test("A file that does not decode throws rather than reading as the defaults")
    func corruptFileThrows() throws {
        try withBundle { bundleURL in
            try Data("{ not json".utf8).write(
                to: VMBundleLayout(bundleURL: bundleURL).hostStateURL)

            #expect(throws: VMBundleSidecarFile.Unreadable.self) {
                try storage.loadHostState(from: bundleURL)
            }
        }
    }

    /// Only absence means "nothing recorded": a file that is there but cannot be
    /// opened still holds state, whatever the reason it cannot be read.
    @Test("A file that cannot be opened throws rather than reading as the defaults")
    func unopenableFileThrows() throws {
        try withBundle { bundleURL in
            let url = VMBundleLayout(bundleURL: bundleURL).hostStateURL
            try storage.saveHostState(everyFieldSet(), to: bundleURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0], ofItemAtPath: url.path(percentEncoded: false))
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
            }

            #expect(throws: VMBundleSidecarFile.Unreadable.self) {
                try storage.loadHostState(from: bundleURL)
            }
        }
    }

    @Test("A key the file does not carry decodes to its default")
    func absentKeysTakeTheirDefaults() throws {
        try withBundle { bundleURL in
            try Data(#"{"displayPreference":"fullscreen"}"#.utf8).write(
                to: VMBundleLayout(bundleURL: bundleURL).hostStateURL)

            #expect(
                try storage.loadHostState(from: bundleURL)
                    == VMHostState(displayPreference: .fullscreen))
        }
    }

    @Test("Writing the host state leaves config.json alone")
    func hostStateIsItsOwnFile() throws {
        try withBundle { bundleURL in
            let config = VMConfiguration(name: "Apart", guestOS: .linux, bootMode: .efi)
            try storage.saveConfiguration(config, to: bundleURL)
            let configBefore = try Data(
                contentsOf: VMBundleLayout(bundleURL: bundleURL).configURL)

            try storage.saveHostState(everyFieldSet(), to: bundleURL)

            #expect(
                try Data(contentsOf: VMBundleLayout(bundleURL: bundleURL).configURL)
                    == configBefore)
        }
    }
}
