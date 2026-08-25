import AppKit
import Foundation
import Testing

@testable import Kernova

/// The toolbar host that carries the running marker beside the main window's
/// title.
@Suite("Ephemeral Chip Toolbar Host Tests", .admissionGated)
@MainActor
struct EphemeralChipToolbarHostTests {
    /// The item stays in the toolbar for the window's lifetime, so an empty
    /// host has to hold no width — a slot left behind pushes a real item into
    /// the overflow menu.
    @Test("The host holds no width until the chip is shown")
    func collapsedHostHasNoWidth() {
        let host = EphemeralChipToolbarHost()
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 0)

        host.setChipVisible(true)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)

        host.setChipVisible(false)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 0)
    }
}

/// Ephemeral Mode's model rules: the flag/baseline pairing, what survives a
/// revert, and what a clone inherits.
@Suite("Ephemeral Mode Configuration Tests", .admissionGated)
struct EphemeralModeConfigurationTests {
    private func makeConfig() -> VMConfiguration {
        VMConfiguration(name: "Throwaway", guestOS: .linux, bootMode: .efi)
    }

    @Test("A fresh configuration is not ephemeral")
    func defaultsOff() {
        let config = makeConfig()
        #expect(!config.ephemeralModeEnabled)
        #expect(config.ephemeralBaselineSnapshotID == nil)
    }

    @Test("Turning the mode on records the baseline")
    func enablingRecordsTheBaseline() {
        var config = makeConfig()
        let baseline = UUID()

        config.applyEphemeralMode(enabled: true, baseline: baseline)

        #expect(config.ephemeralModeEnabled)
        #expect(config.ephemeralBaselineSnapshotID == baseline)
    }

    @Test("Turning the mode off clears the baseline choice")
    func disablingClearsTheBaseline() {
        var config = makeConfig()
        config.applyEphemeralMode(enabled: true, baseline: UUID())

        config.applyEphemeralMode(enabled: false, baseline: UUID())

        #expect(!config.ephemeralModeEnabled)
        #expect(config.ephemeralBaselineSnapshotID == nil)
    }

    @Test("The mode round-trips through config.json")
    func codingRoundTrip() throws {
        var config = makeConfig()
        let baseline = UUID()
        config.applyEphemeralMode(enabled: true, baseline: baseline)

        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.ephemeralModeEnabled)
        #expect(decoded.ephemeralBaselineSnapshotID == baseline)
    }

    @Test("A configuration written without the ephemeral keys decodes as off")
    func missingKeysDecodeOff() throws {
        var config = makeConfig()
        config.applyEphemeralMode(enabled: true, baseline: UUID())
        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "ephemeralModeEnabled")
        object.removeValue(forKey: "ephemeralBaselineSnapshotID")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: stripped)

        #expect(!decoded.ephemeralModeEnabled)
        #expect(decoded.ephemeralBaselineSnapshotID == nil)
    }

    @Test("A revert keeps the mode that asked for it, not the snapshot's copy")
    func revertKeepsTheModePolicy() {
        var live = makeConfig()
        let baseline = UUID()
        live.applyEphemeralMode(enabled: true, baseline: baseline)
        // Captured before the mode was ever turned on.
        let captured = makeConfig()

        let restored = live.adoptingSnapshotState(captured)

        #expect(restored.ephemeralModeEnabled)
        #expect(restored.ephemeralBaselineSnapshotID == baseline)
    }

    @Test("A revert on a VM that is no longer ephemeral doesn't take the mode back")
    func revertDoesNotResurrectTheMode() {
        let live = makeConfig()
        var captured = makeConfig()
        captured.applyEphemeralMode(enabled: true, baseline: UUID())

        let restored = live.adoptingSnapshotState(captured)

        #expect(!restored.ephemeralModeEnabled)
        #expect(restored.ephemeralBaselineSnapshotID == nil)
    }

    @Test("A clone is not ephemeral — its bundle holds none of the snapshots")
    func cloneClearsTheMode() {
        var original = makeConfig()
        original.applyEphemeralMode(enabled: true, baseline: UUID())

        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(!clone.ephemeralModeEnabled)
        #expect(clone.ephemeralBaselineSnapshotID == nil)
    }
}

/// What a `VMInstance` reports about its ephemeral baseline.
@Suite("Ephemeral Mode Instance Tests", .serialized, .admissionGated)
@MainActor
struct EphemeralModeInstanceTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.ephemeral.instance")

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(name: "Throwaway", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        return VMInstance(
            configuration: config, bundleURL: bundleURL, status: status, preferences: preferences)
    }

    @Test("A VM with the mode off has no baseline")
    func noBaselineWhileOff() {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Clean")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
        instance.configuration.ephemeralBaselineSnapshotID = snapshot.id

        #expect(instance.ephemeralBaselineSnapshot == nil)
        #expect(!instance.isEphemeralBaseline(snapshot))
    }

    @Test("The baseline resolves through the manifest")
    func baselineResolves() {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Clean")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
        instance.configuration.applyEphemeralMode(enabled: true, baseline: snapshot.id)

        #expect(instance.ephemeralBaselineSnapshot == snapshot)
        #expect(instance.isEphemeralBaseline(snapshot))
    }

    @Test("A baseline the manifest no longer lists resolves to nothing")
    func danglingBaselineResolvesToNothing() {
        let instance = makeInstance()
        instance.configuration.applyEphemeralMode(enabled: true, baseline: UUID())

        #expect(instance.ephemeralBaselineSnapshot == nil)
        #expect(!instance.hasLiveEphemeralSession)
    }

    @Test("The running marker needs a live session, not just the mode")
    func liveSessionMarkerFollowsTheSession() {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Clean")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
        instance.configuration.applyEphemeralMode(enabled: true, baseline: snapshot.id)

        // Stopped: the mode is on, but nothing is running to discard.
        #expect(!instance.hasLiveEphemeralSession)
    }

    @Test("A power-off fires the hook the ephemeral revert hangs off")
    func powerOffFiresTheHook() {
        let instance = makeInstance(status: .running)
        var poweredOff = 0
        instance.onPoweredOff = { poweredOff += 1 }

        instance.resetToStopped()

        #expect(poweredOff == 1)
        #expect(instance.status == .stopped)
    }
}
